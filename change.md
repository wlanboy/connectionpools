# DB-Passwortrotation ohne Downtime

Das Passwort des DB-Users `pool` lässt sich im laufenden Betrieb wechseln. Kein Pod wird neu gestartet und kein Request schlägt fehl. Dafür arbeiten drei Teile zusammen:

| Teil | Datei | Aufgabe |
|------|-------|---------|
| MySQL Dual Password | `change-password.sh` | altes und neues Passwort gelten während der Umstellung parallel |
| Secret als Volume | `pool-chart/templates/deployment.yaml`, `secret.yaml` | kubelet schreibt das neue Passwort in den laufenden Pod |
| Hikari-Umstellung | `DbCredentialsRotator`, `DbCredentialsEndpoint` | Pool übernimmt das neue Passwort, Skript prüft den Stand |

## Ablauf

```
change-password.sh
  0. k8s:    neues Passwort als pending-password im Secret ablegen
  1. MySQL:  ALTER USER ... RETAIN CURRENT PASSWORD   → alt + neu gültig
  2. k8s:    Secret patchen (password + version), Pods annotieren
  3. Pods:   Rotator liest Datei, testet, tauscht Credentials, Soft-Evict
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

## 3. Anwendung: Hikari-Pool umstellen

`DbCredentialsRotator` prüft alle 5 Sekunden (`app.db-credentials.poll-interval`) die Datei `password` im gemounteten Verzeichnis. `@EnableScheduling` in `PoolApplication` aktiviert den Job. Weicht das Passwort vom aktuellen ab, passiert Folgendes:

```java
// 1. Neues Passwort mit separater Verbindung testen.
//    Schlägt das fehl, bleibt der Pool unverändert. Nächster Versuch beim nächsten Poll.
try (Connection probe = DriverManager.getConnection(dataSource.getJdbcUrl(), current.getUsername(), password)) {
    probe.isValid(5);
}

// 2. Credentials tauschen. Hikari liest sie bei jeder neuen Verbindung.
dataSource.getHikariConfigMXBean().setCredentials(Credentials.of(current.getUsername(), password));

// 3. Soft-Evict: freie Verbindungen sofort schließen, belegte erst bei Rückgabe an den Pool.
dataSource.getHikariPoolMXBean().softEvictConnections();
```

Durch den Soft-Evict arbeiten laufende Requests mit ihrer bisherigen Verbindung zu Ende. Neue Verbindungen baut Hikari mit dem neuen Passwort auf.

Der Test in Schritt 1 deckt auch den Fall ab, dass das Secret schon aktualisiert ist, MySQL das Passwort aber noch nicht kennt. Der Pool behält dann einfach die alten Credentials.

## 4. Status-Endpoint

`DbCredentialsEndpoint` stellt `/actuator/dbcredentials` bereit. Das Passwort selbst wird nie ausgegeben:

```json
{ "version": "20261008184500", "rotatedAt": "2026-10-08T16:45:03Z",
  "active": 1, "idle": 9, "total": 10, "waiting": 0 }
```

Das Skript wartet für jeden Pod, bis `version` der neuen Version entspricht. Erst dann wird das alte Passwort in MySQL verworfen.

## 5. Das Skript `change-password.sh`

```bash
./change-password.sh              # zufälliges Passwort (24 Zeichen)
./change-password.sh 'MeinPasswort'
```

Username und aktuelles Passwort liest das Skript aus dem Secret.

Einige Details:

- **Fortsetzen nach Abbruch:** Vor Schritt 1 legt das Skript das neue Passwort als `pending-password` (und `pending-version`) im Secret ab. Findet ein späterer Lauf diese Schlüssel, nimmt er dasselbe Passwort statt eines neuen. Ein neues Passwort mit `RETAIN CURRENT PASSWORD` würde das Passwort aus dem ersten Lauf zum Secondary machen und das ursprüngliche verwerfen, mit dem Pods eventuell noch arbeiten. Schritt 1 entfällt, wenn der Login mit dem neuen Passwort schon klappt. Nach Schritt 4 entfernt das Skript die `pending-*`-Schlüssel. Der Rotator liest nur `password` und `version`, die zusätzlichen Dateien im Volume stören nicht.

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
- **Timeout:** Stellt ein Pod nicht innerhalb von 180 Sekunden um, bricht das Skript ab, ohne das alte Passwort zu verwerfen.

## Einschränkungen

- Pods lesen das Passwort beim Start aus der Umgebungsvariable, also den Stand des Secrets zum Startzeitpunkt. Ein abweichender Stand wird danach über das Volume nachgezogen.
- Das Skript wartet nur auf Pods, die in Schritt 2 im Status `Running` sind. Ein Pod, der genau während der Rotation startet, wird nicht abgewartet. Er stellt zwar über den Rotator um, aber Schritt 4 kann vorher laufen.
- Der Container-Name ist für die lokale Docker-MySQL fest im Skript hinterlegt (`DB_CONTAINER`).
- Ein `helm upgrade` während einer unterbrochenen Rotation übernimmt die `pending-*`-Schlüssel per `lookup` mit. Das ist gewollt, der nächste Lauf setzt fort.
