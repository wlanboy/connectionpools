# Passwortrotation ohne Downtime in eine bestehende Anwendung einbauen

Diese Anleitung beschreibt, wie eine vorhandene Spring-Boot-Anwendung das Passwort ihres DB-Users im laufenden Betrieb wechseln kann, ohne Pod-Neustart und ohne fehlgeschlagene Requests. Grundlage ist MySQL Dual Password (`change-password.sh`). Die zweite Methode, der Wechsel zwischen zwei DB-Usern, steht in [switch.md](switch.md).

## Prinzip

| Teil | Aufgabe |
|------|---------|
| MySQL Dual Password | altes und neues Passwort gelten während der Umstellung parallel |
| Secret als Volume | kubelet schreibt das neue Passwort in den laufenden Pod |
| Hikari-Credentials-Provider | Hikari liest Username und Passwort bei jeder neuen Verbindung aus der Datei |
| Status-Endpoint | `/actuator/dbcredentials` zeigt, welchen Secret-Stand ein Pod nutzt |
| Rotationsskript | führt die Schritte in der richtigen Reihenfolge aus und wartet auf alle Pods |

```
change-password.sh
  0. k8s:    neues Passwort als pending-password im Secret ablegen
  1. MySQL:  ALTER USER ... RETAIN CURRENT PASSWORD   → alt + neu gültig
  2. k8s:    Secret patchen (password + version), Pods annotieren
  3. Pods:   kubelet schreibt die Datei, neue Verbindungen nutzen das neue Passwort
             Skript pollt /actuator/dbcredentials bis version == neu
  4. MySQL:  ALTER USER ... DISCARD OLD PASSWORD      → nur noch neu gültig
```

Bricht das Skript vor Schritt 4 ab, bleiben beide Passwörter gültig. Ein erneuter Lauf setzt die Rotation mit demselben Passwort fort.

## Voraussetzungen

- **HikariCP ab 6.x.** Erst dort gibt es `HikariCredentialsProvider`. Dieses Projekt nutzt Spring Boot 4.1 mit Hikari 7.0.2. Die eingesetzte Version zeigt `mvn dependency:tree -Dincludes=com.zaxxer:HikariCP`. Bei älteren Boot-Versionen lässt sie sich über die Property `hikari.version` im `pom.xml` anheben.
- **MySQL ab 8.0.14** für `RETAIN CURRENT PASSWORD` / `DISCARD OLD PASSWORD`. Andere Datenbanken haben kein Dual Password, dafür gibt es [switch.md](switch.md).
- **Spring Boot Actuator**, damit das Skript den Stand je Pod abfragen kann.
- **`mysql`-Client auf dem Rechner, der das Skript ausführt**, mit Netzwerkzugang zur DB (`DB_HOST`, `DB_PORT` aus `config.env`).
- **`curl` im Container-Image.** Das Skript ruft den Endpoint per `kubectl exec ... curl` auf. Fehlt `curl`, die Abfrage auf `wget` oder `kubectl port-forward` umstellen.
- **Rechte für das Skript.** Wer es ausführt, muss das Secret lesen und patchen sowie Pods auflisten, annotieren und `exec` ausführen dürfen.

## Schritt 1: Klassen übernehmen

Die drei Klassen aus [src/main/java/com/example/pool/credentials/](src/main/java/com/example/pool/credentials/) in die Anwendung kopieren und das Package anpassen. Das Package muss im Component-Scan der Anwendung liegen, also unterhalb der Klasse mit `@SpringBootApplication`.

| Klasse | Aufgabe |
|--------|---------|
| `SecretFileCredentialsProvider` | liest `username` und `password` aus dem Secret-Verzeichnis, fällt bei Lesefehlern auf den letzten bekannten Stand zurück |
| `SecretFileCredentialsInstaller` | `BeanPostProcessor`, hängt den Provider an jede `HikariDataSource`, wenn `app.db-credentials.dir` gesetzt ist |
| `DbCredentialsEndpoint` | Actuator-Endpoint `dbcredentials` mit `version`, `username` und Pool-Zahlen, ohne Passwort |

Der Provider liest die Dateien bei jedem neuen Verbindungsaufbau:

```java
public Credentials getCredentials() {
    try {
        Path data = snapshot();
        String username = Files.readString(data.resolve("username")).strip();
        String password = Files.readString(data.resolve("password")).strip();
        if (!username.equals(lastKnown.getUsername()) || !password.equals(lastKnown.getPassword())) {
            lastKnown = Credentials.of(username, password);
        }
    }
    catch (IOException ex) {
        // letztes bekanntes Passwort weiterverwenden
    }
    return lastKnown;
}
```

`snapshot()` löst den Symlink `..data` auf, den kubelet bei jedem Secret-Update atomar tauscht. So stammen Username und Passwort immer aus demselben Stand.

Worauf man in einer bestehenden Anwendung achten muss:

- **Eigene DataSource-Bean.** Der Installer greift nur bei Beans vom Typ `HikariDataSource`. Wrappt die Anwendung die DataSource für Tracing oder Routing, bevor sie als Bean registriert ist, sieht der Installer sie nicht. Dann den Provider direkt dort setzen, wo die `HikariDataSource` gebaut wird.
- **Mehrere DataSources.** Der Installer hängt denselben Provider-Typ mit demselben Verzeichnis an jede `HikariDataSource`. Bei mehreren Datenbanken mit unterschiedlichen Zugangsdaten muss der Installer pro Bean ein eigenes Verzeichnis bekommen.
- **Zeitpunkt.** Der Provider muss gesetzt sein, bevor der Pool startet. Danach versiegelt Hikari die Konfiguration. Ein `BeanPostProcessor` erfüllt das, solange nichts in der Anwendung schon während der Bean-Initialisierung der DataSource eine Verbindung holt.
- **Startwert.** Initial übernimmt der Provider `spring.datasource.username` und `spring.datasource.password`. Sie bleiben als Fallback nötig, falls die Datei beim Start nicht lesbar ist.

## Schritt 2: Konfiguration

In `application.properties` (oder als Env-Variablen im Deployment):

```properties
# Verzeichnis des gemounteten Secrets. Ohne diesen Wert bleibt alles beim Alten.
app.db-credentials.dir=/etc/pool-db
management.endpoints.web.exposure.include=health,dbcredentials

# Nach einem Wechsel sind spätestens nach dieser Zeit alle Verbindungen neu aufgebaut
spring.datasource.hikari.max-lifetime=300000
spring.datasource.hikari.keepalive-time=180000
spring.datasource.hikari.idle-timeout=180000
```

`max-lifetime` bestimmt, wie lange Verbindungen mit dem alten Passwort noch offen sind. Der Hikari-Default sind 30 Minuten, hier 5 Minuten. `keepalive-time` und `idle-timeout` müssen kleiner sein als `max-lifetime`. Ist der Endpoint öffentlich erreichbar, die Exposure mit `management.server.port` auf den Management-Port beschränken.

## Schritt 3: Datenbank

Der App-User braucht einmalig ein Privileg, damit er sein eigenes Passwort mit `RETAIN CURRENT PASSWORD` ändern darf. Root braucht das Skript danach nicht mehr:

```sql
GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO '<app-user>'@'%';
```

Das Privileg gilt nur für den eigenen Account. Im Projekt vergibt `db.sh` es bei jedem Lauf.

## Schritt 4: Kubernetes

### Secret

Das Secret braucht drei Schlüssel:

| Schlüssel | Inhalt |
|-----------|--------|
| `username` | DB-User |
| `password` | aktuelles Passwort |
| `version` | frei wählbarer Stand, das Skript setzt einen Zeitstempel, initial `initial` |

Das Secret darf nicht `immutable: true` sein. Wird es per Helm verwaltet, muss ein `helm upgrade` den rotierten Stand übernehmen, sonst setzt es das Passwort auf den Wert aus `values.yaml` zurück. Dafür `lookup` verwenden ([pool-chart/templates/secret.yaml](pool-chart/templates/secret.yaml)):

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-db" .Values.name) }}
apiVersion: v1
kind: Secret
metadata:
  name: {{ .Values.name }}-db
type: Opaque
{{- if $existing }}
data:
  {{- toYaml $existing.data | nindent 2 }}
{{- else }}
stringData:
  username: {{ .Values.database.username | quote }}
  password: {{ .Values.database.password | quote }}
  version: "initial"
{{- end }}
```

`lookup` liefert bei `helm template` und `--dry-run` nichts, dort erscheint immer der Startwert. Kommt das Secret aus einem anderen Werkzeug (Argo CD, External Secrets, Sealed Secrets), muss dieses Werkzeug den gepatchten Stand ebenfalls stehen lassen. Bei Argo CD z. B. die Felder per `ignoreDifferences` ausnehmen.

### Deployment

Das Secret zusätzlich als Volume mounten. Env-Variablen liest der Container nur beim Start. Dateien in einem Secret-Volume aktualisiert kubelet dagegen im laufenden Pod ([pool-chart/templates/deployment.yaml](pool-chart/templates/deployment.yaml)):

```yaml
spec:
  volumes:
    - name: db-credentials
      secret:
        secretName: pool-db
  containers:
    - name: pool
      env:
        # bleiben als Startwert und Fallback
        - name: SPRING_DATASOURCE_USERNAME
          valueFrom: { secretKeyRef: { name: pool-db, key: username } }
        - name: SPRING_DATASOURCE_PASSWORD
          valueFrom: { secretKeyRef: { name: pool-db, key: password } }
        - name: APP_DBCREDENTIALS_DIR
          value: /etc/pool-db
        - name: MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE
          value: health,dbcredentials
      volumeMounts:
        # kein subPath, sonst bekommt der Container keine Updates
        - name: db-credentials
          mountPath: /etc/pool-db
          readOnly: true
```

Das Skript wählt die Pods über das Label `app: <name>` aus.

## Schritt 5: Rotationsskript anpassen

[change-password.sh](change-password.sh) ist auf die lokale Demo zugeschnitten. Diese Stellen an die eigene Umgebung anpassen:

| Stelle | Demo | Anpassen auf |
|--------|------|--------------|
| `APP`, `NAMESPACE`, `SECRET` | `pool`, `pool`, `pool-db` | Name der Anwendung, Namespace, Secret |
| `mysql_as()` | `mysql -h "$DB_HOST" -P "$DB_PORT"` mit `MYSQL_PWD`, Host und Port aus `config.env` | DB-Zugang der eigenen Umgebung, z. B. aus einem Job oder Bastion-Host |
| `pod_synced()` | `curl localhost:8080/actuator/dbcredentials`, Container `-c "$APP"` | Management-Port und Container-Name der Anwendung |
| Pod-Selector | `-l app="$APP"` | Label des Deployments |
| `TIMEOUT` | 180 s | länger, wenn viele Pods oder langsame Starts |

Aufruf:

```bash
./change-password.sh              # zufälliges Passwort (24 Zeichen)
./change-password.sh 'MeinPasswort'
```

Was das Skript absichert:

- **Reihenfolge.** Erst MySQL, dann Secret. Der Provider testet ein neues Passwort nicht vorab. Stünde im Secret ein Passwort, das MySQL noch nicht kennt, schlügen neue Verbindungen fehl. Das Secret deshalb nie von Hand ändern.
- **Fortsetzen nach Abbruch.** Das neue Passwort liegt vorab als `pending-password` / `pending-version` im Secret. Ein erneuter Lauf nimmt dasselbe Passwort. Ein zweites `RETAIN CURRENT PASSWORD` mit einem anderen Passwort würde sonst das ursprüngliche verwerfen, mit dem die Pods eventuell noch arbeiten.
- **Passwort nicht in der Prozessliste.** Der Secret-Patch geht über stdin (`--patch-file /dev/stdin`), das MySQL-Passwort über `MYSQL_PWD`.
- **Schneller Volume-Sync.** kubelet gleicht Secret-Volumes nur periodisch ab (bis zu 1 bis 2 Minuten). Eine Annotation am Pod löst den Abgleich sofort aus.
- **Startende Pods.** Das Skript erfasst alle Pods außer `Succeeded`/`Failed`. Pods, die währenddessen verschwinden, überspringt es.
- **SQL-Escaping.** Das Skript escaped `\` und `'` im Passwort.

## Schritt 6: Testen

1. Anwendung mit den neuen Klassen deployen und prüfen:
   ```bash
   kubectl exec <pod> -c <container> -- curl -s localhost:8080/actuator/dbcredentials
   # { "version": "initial", "username": "pool", "active": 0, "idle": 1, "total": 1, "waiting": 0 }
   ```
   `version` muss `initial` sein, nicht `none`. Bei `none` ist der Provider nicht aktiv, meist fehlt dann `app.db-credentials.dir`.
2. Dauerlast starten (im Projekt `./test.sh`).
3. `./change-password.sh` ausführen. Die Last darf keine Fehler zeigen.
4. Im Log jedes Pods erscheint `Neue Verbindungen nutzen DB-User ..., Secret-Version ...`.
5. Nach `max-lifetime` sind alle Verbindungen mit dem neuen Passwort aufgebaut.

## Checkliste

- [ ] Hikari ≥ 6, Actuator vorhanden
- [ ] drei Klassen im Component-Scan
- [ ] `app.db-credentials.dir` gesetzt, Endpoint `dbcredentials` freigegeben
- [ ] `max-lifetime` bewusst gewählt
- [ ] `GRANT APPLICATION_PASSWORD_ADMIN` für den App-User
- [ ] Secret mit `username`, `password`, `version`, nicht immutable
- [ ] Secret als Volume ohne `subPath` gemountet
- [ ] Helm/GitOps überschreibt den rotierten Stand nicht
- [ ] Skript auf DB-Zugang, Namespace, Labels und Port angepasst

## Einschränkungen

- Hikari tauscht offene Verbindungen nicht aktiv aus, sie laufen bis `max-lifetime` weiter. MySQL prüft das Passwort nur beim Login, offene Sessions überleben `DISCARD OLD PASSWORD`. Muss ein kompromittiertes Passwort sofort aus allen Verbindungen verschwinden, zusätzlich `HikariPoolMXBean.softEvictConnections()` aufrufen oder die Pods neu starten.
- Die Env-Variable mit dem Passwort ist nach einer Rotation veraltet. Sie dient nur noch als Fallback, wenn die Datei nicht lesbar ist.
- `change-password.sh` und `change-user.sh` erkennen gegenseitig eine unterbrochene Rotation (`pending-*`-Schlüssel) und brechen dann ab. Erst die unterbrochene Rotation abschließen.
- Ein `helm upgrade` während einer unterbrochenen Rotation übernimmt die `pending-*`-Schlüssel per `lookup`. Das ist gewollt, der nächste Lauf setzt fort.
- Das Skript speichert das alte Passwort nicht. Wie man zurückrotiert und warum `helm rollback` das Secret zurücksetzt, steht in [readme.md, Rollback](readme.md#rollback).
