# connectionpools

Demo für eine Rotation des Datenbank-Passworts ohne Downtime. Eine Spring-Boot-Anwendung (Java 25, HikariCP 7) läuft in einem lokalen kind-Cluster mit Istio und spricht mit einer MySQL, die als Docker-Container außerhalb des Clusters läuft. Das Passwort des DB-Users `pool` lässt sich im laufenden Betrieb wechseln: Kein Pod wird neu gestartet, kein Request schlägt fehl.

Die Anwendung selbst ist eine kleine Nachrichtenliste (`/api/messages`, Web-UI unter `http://pool.localhost/`). Sie existiert vor allem, damit es Traffic über den Connection-Pool gibt, den man während der Rotation beobachten kann.

## Bausteine

| Teil | Wo | Aufgabe |
|------|----|---------|
| MySQL-Container | `db.sh` | DB `pool`, User `pool` (plus `pool_a`/`pool_b` für den A/B-Wechsel), Privileg für Dual Password |
| Image + Deployment | `install.sh`, `Dockerfile`, `pool-chart/` | Image bauen, in `localhost:5001` pushen, Helm-Release installieren |
| Secret als Volume | `pool-chart/templates/secret.yaml`, `deployment.yaml` | kubelet schreibt ein geändertes Passwort in den laufenden Pod |
| Credentials-Provider | `src/main/java/com/example/pool/credentials/` | Hikari liest das Passwort bei jeder neuen Verbindung aus der Datei |
| Status-Endpoint | `/actuator/dbcredentials` | zeigt Secret-Version und Pool-Zustand je Pod |
| Rotation | `change-password.sh` | Passwort in MySQL und Secret wechseln |
| Rotation (A/B) | `change-user.sh` | zwischen zwei DB-Usern wechseln, ohne Dual Password |
| Lasttest | `test.sh` | ruft die API jede Sekunde auf und zählt Fehler |

Voraussetzungen: Docker, ein kind-Cluster mit Istio-Ingressgateway, eine lokale Registry auf `localhost:5001`, dazu `kubectl`, `helm`, `jq` und `openssl`.

## Ablauf

```
1. ./db.sh                  MySQL-Container starten
2. ./install.sh             Image bauen, Helm-Release installieren
   helm status pool -n pool Release prüfen
3. ./test.sh                in einem zweiten Terminal: Dauerlast
4. ./change-password.sh     Passwort rotieren, test.sh meldet 0 Fehler
   oder ./change-user.sh    auf den anderen DB-User wechseln
```

## 1. db.sh

Startet MySQL 9.7 als Docker-Container `mysql-pool` auf Port 3306 mit Volume `mysql-pool-data`. Das Skript ist idempotent:

- Container läuft schon: nichts tun.
- Container existiert, ist aber gestoppt: `docker start`.
- Container fehlt: `docker run` mit DB `pool`, User `pool` / `poolsecret`, root / `rootsecret`.

Danach wartet es bis zu 120 Sekunden, bis MySQL per TCP (`-h 127.0.0.1`) antwortet. TCP ist wichtig, weil der temporäre Init-Server beim ersten Start nur über den Socket erreichbar ist und sonst fälschlich als bereit gälte. Der Check läuft als root, nicht als `pool`, denn nach einer Rotation stimmt `poolsecret` nicht mehr.

Sobald MySQL bereit ist, vergibt das Skript bei jedem Lauf:

```sql
GRANT APPLICATION_PASSWORD_ADMIN ON *.* TO 'pool'@'%';
```

Damit darf `pool` an seinem eigenen Account `RETAIN CURRENT PASSWORD` und `DISCARD OLD PASSWORD` ausführen. `change-password.sh` braucht dadurch kein root-Passwort.

Außerdem legt es die User `pool_a` / `poolsecret_a` und `pool_b` / `poolsecret_b` an (`CREATE USER IF NOT EXISTS`), mit denselben Rechten auf die DB `pool` und demselben Privileg. `change-user.sh` schaltet zwischen ihnen um.

## 2. install.sh und helm upgrade --install

`install.sh` erledigt vier Dinge:

1. Image bauen und mit einem Zeitstempel-Tag (`TAG`, überschreibbar) sowie `latest` nach `localhost:5001/pool` pushen.
2. Den Container `mysql-pool` ins Docker-Netzwerk `kind` hängen, damit die Pods ihn erreichen.
3. Namespace `pool` anlegen und mit `istio-injection=enabled` markieren.
4. Das Helm-Chart deployen und auf den Rollout warten.

```bash
helm upgrade --install pool ./pool-chart -n pool \
  --set image.repository=localhost:5001/pool \
  --set image.tag=<TAG>
kubectl rollout status deployment/pool -n pool --timeout=180s
```

`helm upgrade --install` installiert das Release `pool`, wenn es noch nicht existiert, und aktualisiert es sonst. Dasselbe Kommando funktioniert also für den ersten und jeden weiteren Lauf. Weil `image.tag` jedes Mal ein neuer Zeitstempel ist, ändert sich das Pod-Template und Kubernetes rollt neue Pods aus. Mit `latest` allein würde Helm keine Änderung sehen.

Das Chart `pool-chart/` erzeugt:

| Template | Ressource |
|----------|-----------|
| `deployment.yaml` | Deployment `pool`: Env-Variablen für Datasource, Secret als Volume unter `/etc/pool-db`, Probes auf `/actuator/health/*` |
| `secret.yaml` | Secret `pool-db` mit `username`, `password`, `version` |
| `mysql-service.yaml` | Service `mysql` vom Typ `ExternalName` → Container `mysql-pool`; Port-Name `tcp-mysql`, damit Istio kein Protocol Sniffing versucht (MySQL ist server-first) |
| `service.yaml` | Service `pool` auf Port 8080 |
| `gateway.yaml`, `virtualservice.yaml` | Istio-Routing von `pool.localhost` auf den Service |

Besonderheit in `secret.yaml`: Per `lookup` liest Helm das vorhandene Secret aus dem Cluster und übernimmt dessen Daten. Nur beim ersten Install kommt das Passwort aus `values.yaml` (`database.password`, Version `initial`). Ein späteres `helm upgrade` setzt ein rotiertes Passwort deshalb nicht auf `poolsecret` zurück.

## 3. helm status

```bash
helm status pool -n pool
```

Zeigt den Zustand des Releases: Namespace, `STATUS` (`deployed`, `failed`, `pending-upgrade` …), die Revisionsnummer und den Zeitpunkt des letzten Deployments. Jeder `helm upgrade --install`-Lauf erhöht die Revision um eins.

Nützliche Varianten:

```bash
helm status pool -n pool --show-resources   # erzeugte Kubernetes-Objekte auflisten
helm history pool -n pool                   # alle Revisionen
helm get values pool -n pool                # mit --set übergebene Werte, z. B. image.tag
```

`helm status` sagt nur, ob Helm die Manifeste anwenden konnte. Ob die Pods laufen, zeigt `kubectl rollout status` (macht `install.sh` bereits) oder `kubectl get pods -n pool`.

## 4. Wie die Anwendung das Passwort wechselt

Env-Variablen aus einem Secret werden nur beim Containerstart gelesen. Deshalb ist das Secret zusätzlich als Volume gemountet (ohne `subPath`, sonst kommen keine Updates an). Ändert sich das Secret, schreibt kubelet die Dateien `password` und `version` im laufenden Pod neu.

`SecretFileCredentialsInstaller` hängt beim Start einen `SecretFileCredentialsProvider` an die `HikariDataSource`, sofern `app.db-credentials.dir` gesetzt ist (im Chart über `APP_DBCREDENTIALS_DIR`). Hikari fragt den Provider bei jedem neuen Verbindungsaufbau, der Provider liest die Datei. Bestehende Verbindungen laufen bis zu ihrer `maxLifetime` weiter. Das ist unkritisch, weil MySQL das Passwort nur beim Login prüft.

Der Provider liest `username` und `password`. Beide Dateien kommen aus demselben Secret-Stand: kubelet legt jeden Stand in einem eigenen Verzeichnis ab und tauscht den Symlink `..data` atomar, der Provider löst diesen Symlink einmal auf und liest beide Dateien von dort. So kann er nicht den neuen User mit dem alten Passwort kombinieren.

`/actuator/dbcredentials` liefert je Pod:

```json
{ "version": "20261008184500", "username": "pool_a", "active": 1, "idle": 9, "total": 10, "waiting": 0 }
```

`version` und `username` beschreiben den Stand, mit dem die nächste neue Verbindung aufgebaut wird. Das Passwort wird nie ausgegeben.

## 5. change-password.sh

```bash
./change-password.sh              # zufälliges Passwort, 24 Zeichen
./change-password.sh 'MeinPasswort'
```

Username und aktuelles Passwort liest das Skript aus dem Secret `pool-db`. Es meldet sich per `docker exec` im Container `mysql-pool` als `pool` selbst an.

### Schritt 0: Passwort vormerken

Das neue Passwort und eine Version (Zeitstempel) landen zuerst als `pending-password` / `pending-version` im Secret. Findet ein späterer Lauf diese Schlüssel, setzt er genau diese Rotation fort, statt ein weiteres Passwort zu erzeugen. Ein zweites `RETAIN CURRENT PASSWORD` würde sonst das ursprüngliche Passwort verwerfen, mit dem die Pods eventuell noch arbeiten.

### Schritt 1: MySQL, altes und neues Passwort gültig

```sql
ALTER USER USER() IDENTIFIED BY '<neu>' RETAIN CURRENT PASSWORD;
```

Klappt der Login mit dem neuen Passwort schon, wird der Schritt übersprungen. Klappt weder neu noch alt, bricht das Skript ab.

### Schritt 2: Secret patchen, Pods anstoßen

`password` und `version` im Secret werden auf den neuen Stand gesetzt. Der Patch läuft über stdin (`--patch-file /dev/stdin`), damit das Passwort nicht in der Prozessliste auftaucht.

kubelet gleicht Secret-Volumes nur periodisch ab (bis zu 1–2 Minuten). Eine Annotation `db-credentials/version=<VERSION>` an jedem Pod löst den Abgleich sofort aus. Erfasst werden alle Pods außer `Succeeded`/`Failed`, also auch solche, die gerade starten.

### Schritt 3: Auf jeden Pod warten

Für jeden Pod ruft das Skript per `kubectl exec` `curl localhost:8080/actuator/dbcredentials` auf, bis `version` der neuen Version entspricht. Ausgabe pro Pod: Pool-Zahlen (`active`, `idle`, `total`, `waiting`). Pods, die währenddessen verschwinden, werden übersprungen. Nach 180 Sekunden ohne Erfolg bricht das Skript ab, beide Passwörter bleiben gültig.

### Schritt 4: Altes Passwort verwerfen

```sql
ALTER USER USER() DISCARD OLD PASSWORD;
```

Dafür meldet sich das Skript mit dem neuen Passwort an. Danach entfernt es `pending-password` und `pending-version` aus dem Secret.

### Reihenfolge

Die Reihenfolge ist entscheidend: erst MySQL, dann Secret, dann warten, dann verwerfen. Würde das Secret vor MySQL geändert, bekämen neue Verbindungen ein Passwort, das MySQL noch nicht kennt. Das Secret deshalb nie von Hand ändern.

```
          MySQL akzeptiert      Secret / Pods           neue Verbindungen
Start     alt                   alt                     alt
Schritt 1 alt + neu             alt                     alt
Schritt 2 alt + neu             neu (kubelet-Sync)      alt → neu
Schritt 3 alt + neu             neu, bestätigt          neu
Schritt 4 neu                   neu                     neu
```

Details und Einschränkungen: [change.md](change.md).

## 6. change-user.sh: zwei User im Wechsel

```bash
./change-user.sh
```

Statt das Passwort eines Users zu ändern, schaltet die Anwendung auf einen anderen User um. `pool_a` und `pool_b` existieren dauerhaft mit festen Passwörtern, in der Datenbank ändert sich beim Wechsel nichts, root ist nicht nötig. Das Verfahren braucht kein Dual Password und funktioniert deshalb auch mit PostgreSQL, Oracle oder SQL Server. Beim ersten Lauf ist der aktive User noch `pool`, das Skript wechselt dann auf `pool_a`, danach immer zwischen `pool_a` und `pool_b`.

| Schritt | Aktion |
|---------|--------|
| 0 | Ziel-User und Version als `pending-username` / `pending-version` im Secret ablegen |
| 1 | Login als Ziel-User prüfen, sonst Abbruch vor jeder Änderung |
| 2 | `username`, `password` und `version` gemeinsam im Secret patchen, Pods annotieren |
| 3 | warten, bis jeder Pod die neue `version` und den neuen `username` meldet, `pending-*` entfernen |

Neue Verbindungen nutzen den neuen User, sobald kubelet das Secret in den Pod geschrieben hat. Offene Verbindungen des alten Users laufen bis zu ihrer `maxLifetime` weiter. Beide User bleiben gültig, deshalb geht dabei kein Request verloren.

Bricht das Skript ab, setzt ein erneuter Lauf den Wechsel auf denselben User fort, statt zurückzuschalten. `change-password.sh` und `change-user.sh` erkennen gegenseitig eine unterbrochene Rotation und brechen dann ab.

Worauf man beim A/B-Wechsel achten muss:

- Beide User brauchen dieselben Rechte. Neue Grants immer an beide vergeben (in `db.sh`).
- In MySQL gehören Tabellen der Datenbank, nicht dem User. In PostgreSQL gehören sie dem User, der sie anlegt. Dort sollten beide User Mitglied einer gemeinsamen Owner-Rolle sein, sonst kann `pool_b` keine Tabellen von `pool_a` ändern.
- Die Passwörter stehen in `db.sh` und `change-user.sh`. Ändert man sie an einer Stelle, muss die andere mitgezogen werden.

## Testen

```bash
./test.sh                      # Terminal 1: GET /api/messages jede Sekunde
./change-password.sh           # Terminal 2
```

`test.sh` gibt pro Request den HTTP-Code aus, Ctrl+C zeigt die Bilanz. Bei korrekter Rotation steht dort `0 fehlgeschlagen`.
