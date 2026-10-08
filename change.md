# DB-Passwortrotation ohne Downtime

Das Passwort des DB-Users `pool` lässt sich im laufenden Betrieb wechseln. Kein Pod wird neu gestartet und kein Request schlägt fehl. Dafür arbeiten drei Teile zusammen:

| Teil | Datei | Aufgabe |
|------|-------|---------|
| MySQL Dual Password | `change-password.sh` | altes und neues Passwort gelten während der Umstellung parallel |
| Secret als Volume | `pool-chart/templates/deployment.yaml`, `secret.yaml` | kubelet schreibt das neue Passwort in den laufenden Pod |
| Hikari-Credentials-Provider | `SecretFileCredentialsProvider`, `SecretFileCredentialsInstaller`, `DbCredentialsEndpoint` | Hikari liest das Passwort bei jeder neuen Verbindung aus der Datei, Skript prüft den Stand |

## Ablauf

```
change-password.sh
  0. k8s:    neues Passwort als pending-password im Secret ablegen
  1. MySQL:  ALTER USER ... RETAIN CURRENT PASSWORD   → alt + neu gültig
  2. k8s:    Secret patchen (password + version), Pods annotieren
  3. Pods:   kubelet schreibt die Datei, neue Verbindungen nutzen das neue Passwort
             Skript pollt /actuator/dbcredentials bis version == neu
  4. MySQL:  ALTER USER ... DISCARD OLD PASSWORD      → nur noch neu gültig
```

Bricht das Skript vor Schritt 4 ab, bleiben beide Passwörter gültig. Ein erneuter Lauf setzt die unterbrochene Rotation mit demselben Passwort fort (siehe Abschnitt 5).

## 1. MySQL: zwei Passwörter gleichzeitig

MySQL (ab 8.0.14) kann pro User ein Secondary Password halten. Das Skript meldet sich als `pool` selbst an, setzt das neue Passwort und behält das alte:

```sql
ALTER USER USER() IDENTIFIED BY '<neu>' RETAIN CURRENT PASSWORD;
-- ... alle Pods umgestellt ...
ALTER USER USER() DISCARD OLD PASSWORD;
```

Root ist dafür nicht nötig. Das eigene Passwort darf jeder User ändern. Für `RETAIN CURRENT PASSWORD` und `DISCARD OLD PASSWORD` braucht `pool` einmalig das Privileg `APPLICATION_PASSWORD_ADMIN`. Es gilt nur für den eigenen Account:

```sql
GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO 'pool'@'%';
```

`db.sh` vergibt den Grant bei jedem Lauf, auch für einen bereits laufenden Container.

In Schritt 4 meldet sich das Skript mit dem neuen Passwort an.

Bestehende Sessions bleiben auch nach `DISCARD OLD PASSWORD` offen. Das Passwort wird nur beim Login geprüft.

`db.sh` prüft die Bereitschaft von MySQL mit dem root-User statt mit `pool`. Sonst würde ein bereits rotiertes Passwort den Check scheitern lassen.

## 2. Kubernetes: Secret als Volume mounten

Umgebungsvariablen aus einem Secret werden nur beim Containerstart gelesen. Deshalb wird das Secret zusätzlich als Volume gemountet. Dateien in einem Secret-Volume aktualisiert kubelet auch im laufenden Pod:

```yaml
env:
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

Das Secret enthält neben `password` einen Schlüssel `version`. Über ihn lässt sich feststellen, welchen Stand ein Pod aktiv hat.

Damit ein späteres `helm upgrade` das rotierte Passwort nicht auf den Wert aus `values.yaml` zurücksetzt, übernimmt `secret.yaml` den aktuellen Stand aus dem Cluster:

```yaml
{{- $existing := lookup "v1" "Secret" .Release.Namespace (printf "%s-db" .Values.name) }}
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

`database.password` in `values.yaml` ist damit nur noch der Startwert beim ersten Install.

## 3. Anwendung: Hikari-Credentials-Provider

Hikari (ab 6.x, hier 7.0.2) kennt das Interface `HikariCredentialsProvider`. Ist ein Provider gesetzt, fragt Hikari ihn bei **jedem neuen Verbindungsaufbau** nach Username und Passwort. `SecretFileCredentialsProvider` liest dafür die Datei `password` aus dem gemounteten Secret:

```java
public Credentials getCredentials() {
    try {
        String password = Files.readString(dir.resolve("password")).strip();
        if (!password.equals(lastKnown.getPassword())) {
            lastKnown = Credentials.of(lastKnown.getUsername(), password);
        }
    } catch (IOException ex) {
        // Datei nicht lesbar: letztes bekanntes Passwort weiterverwenden
    }
    return lastKnown;
}
```

Den Provider hängt `SecretFileCredentialsInstaller` an die `HikariDataSource`. Der Installer ist ein `BeanPostProcessor` und greift nur, wenn `app.db-credentials.dir` gesetzt ist. Das muss vor dem Start des Pools passieren, danach ist die Hikari-Konfiguration versiegelt. Startwert für `lastKnown` ist das Passwort aus `spring.datasource.password`.

Folgen:

- Es gibt keinen Poll-Job und kein `@EnableScheduling`. Sobald kubelet die Datei aktualisiert, nutzt die nächste neue Verbindung das neue Passwort.
- Bestehende Verbindungen werden nicht aktiv getauscht. Sie laufen bis zu ihrer `maxLifetime` (Standard 30 min) weiter. Das ist unkritisch, denn MySQL prüft das Passwort nur beim Login, offene Sessions überleben `DISCARD OLD PASSWORD`.
- Ein Pod, der während der Rotation startet, liest das Passwort aus der Datei und nicht aus der Umgebungsvariable. Er braucht also keine Sonderbehandlung.
- Der Provider testet das neue Passwort nicht vorab. Steht im Secret ein Passwort, das MySQL nicht kennt, schlagen neue Verbindungen fehl. Deshalb setzt `change-password.sh` das Passwort immer zuerst in MySQL (Schritt 1) und erst danach im Secret (Schritt 2). Das Secret nicht von Hand ändern.

## 4. Status-Endpoint

`DbCredentialsEndpoint` stellt `/actuator/dbcredentials` bereit. `version` ist der Inhalt der Datei `version` im Secret-Volume, also der Stand, mit dem die nächste neue Verbindung aufgebaut wird. Das Passwort selbst wird nie ausgegeben:

```json
{ "version": "20261008184500", "active": 1, "idle": 9, "total": 10, "waiting": 0 }
```

Das Skript wartet für jeden Pod, bis `version` der neuen Version entspricht, also bis kubelet das Secret in den Pod geschrieben hat. Erst dann wird das alte Passwort in MySQL verworfen.

## 5. Das Skript `change-password.sh`

```bash
./change-password.sh              # zufälliges Passwort (24 Zeichen)
./change-password.sh 'MeinPasswort'
```

Username und aktuelles Passwort liest das Skript aus dem Secret.

Einige Details:

- **Fortsetzen nach Abbruch:** Vor Schritt 1 legt das Skript das neue Passwort als `pending-password` (und `pending-version`) im Secret ab. Findet ein späterer Lauf diese Schlüssel, nimmt er dasselbe Passwort statt eines neuen. Ein neues Passwort mit `RETAIN CURRENT PASSWORD` würde das Passwort aus dem ersten Lauf zum Secondary machen und das ursprüngliche verwerfen, mit dem Pods eventuell noch arbeiten. Schritt 1 entfällt, wenn der Login mit dem neuen Passwort schon klappt. Nach Schritt 4 entfernt das Skript die `pending-*`-Schlüssel. Provider und Endpoint lesen nur `password` und `version`, die zusätzlichen Dateien im Volume stören nicht.

- **Passwort nicht in der Prozessliste:** Der Secret-Patch wird über stdin übergeben, nicht als Argument.
  ```bash
  jq -n --arg p "$NEW_PASSWORD" --arg v "$VERSION" '{stringData: {password: $p, version: $v}}' \
    | kubectl patch secret "$SECRET" -n "$NAMESPACE" --type merge --patch-file /dev/stdin
  ```
- **Schnellerer Volume-Sync:** kubelet gleicht Secret-Volumes nur periodisch ab (bis zu 1–2 Minuten). Eine Annotation am Pod löst den Abgleich sofort aus.
  ```bash
  kubectl annotate "$pod" -n "$NAMESPACE" db-credentials/version="$VERSION" --overwrite
  ```
- **SQL-Escaping:** `\` und `'` im Passwort werden escaped, bevor es im `ALTER USER` landet.
- **Startende Pods:** Das Skript erfasst alle Pods außer `Succeeded`/`Failed`, also auch solche, die gerade starten. Deren Volume kann noch den alten Stand enthalten. Das Skript wartet, bis sie laufen und die neue Version melden. Pods, die währenddessen verschwinden, werden übersprungen.
- **Timeout:** Meldet ein Pod nicht innerhalb von 180 Sekunden die neue Version, bricht das Skript ab, ohne das alte Passwort zu verwerfen.

## Einschränkungen

- Die Umgebungsvariable mit dem Passwort dient nur noch als Fallback, wenn die Datei nicht lesbar ist.
- Alte Verbindungen werden nicht sofort geschlossen, sondern erst nach `maxLifetime`. Soll ein kompromittiertes Passwort sofort aus allen Verbindungen verschwinden, ist zusätzlich ein Soft-Evict (`HikariPoolMXBean.softEvictConnections()`) oder ein Rolling Restart nötig.
- Der Container-Name ist für die lokale Docker-MySQL fest im Skript hinterlegt (`DB_CONTAINER`).
- Ein `helm upgrade` während einer unterbrochenen Rotation übernimmt die `pending-*`-Schlüssel per `lookup` mit. Das ist gewollt, der nächste Lauf setzt fort.
