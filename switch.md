# Wechsel zwischen zwei DB-Usern ohne Downtime in eine bestehende Anwendung einbauen

Statt das Passwort eines Users zu ändern, schaltet die Anwendung auf einen zweiten User um. Zwei User (`pool_a`, `pool_b`) existieren dauerhaft mit denselben Rechten. Die Anwendung arbeitet immer mit einem davon, `change-user.sh` wechselt im laufenden Betrieb auf den anderen. Die Passwortrotation per MySQL Dual Password steht in [change.md](change.md).

## Wann diese Methode

| | Dual Password ([change.md](change.md)) | Zwei User (diese Datei) |
|---|---|---|
| Datenbank | nur MySQL ab 8.0.14 | jede DB mit Usern und Grants (PostgreSQL, Oracle, SQL Server, MySQL) |
| Änderung in der DB beim Wechsel | `ALTER USER` zweimal | keine |
| Rechte des Skripts in der DB | `APPLICATION_PASSWORD_ADMIN` am eigenen User | nur Login als Ziel-User |
| Pflege | ein User | zwei User mit identischen Grants |
| Aufwand für neue Grants | einmal | für beide User |
| Ablösen eines kompromittierten Passworts | direkt | anderen User aktivieren, danach den alten sperren |

Der Code in der Anwendung ist bei beiden Methoden derselbe. Wer [change.md](change.md) schon umgesetzt hat, muss nur Datenbank, Secret und Skript ergänzen.

## Ablauf

```
change-user.sh
  0. k8s:    Ziel-User als pending-username im Secret ablegen
  1. DB:     Login als Ziel-User prüfen, sonst Abbruch vor jeder Änderung
  2. k8s:    username + password + version gemeinsam patchen, Pods annotieren
  3. Pods:   kubelet schreibt die Dateien, neue Verbindungen nutzen den neuen User
             Skript pollt /actuator/dbcredentials bis version und username neu sind
```

Beide User bleiben die ganze Zeit gültig. Offene Verbindungen des alten Users laufen bis `max-lifetime` weiter, neue Verbindungen nutzen den neuen User. Es geht kein Request verloren.

```
          DB akzeptiert         Secret / Pods           neue Verbindungen
Start     pool_a + pool_b       pool_a                  pool_a
Schritt 2 pool_a + pool_b       pool_b (kubelet-Sync)   pool_a → pool_b
Schritt 3 pool_a + pool_b       pool_b, bestätigt       pool_b
+max-lifetime                                           alle Verbindungen pool_b
```

## Voraussetzungen

Dieselben wie in [change.md](change.md#voraussetzungen), also HikariCP ab 6.x, Actuator, `curl` im Image und Rechte für Secret und Pods. Dual Password ist nicht nötig.

## Schritt 1: Anwendung

Wie in [change.md, Schritt 1 und 2](change.md#schritt-1-klassen-übernehmen) die drei Klassen aus [src/main/java/com/example/pool/credentials/](src/main/java/com/example/pool/credentials/) übernehmen, `app.db-credentials.dir` setzen, Endpoint `dbcredentials` freigeben, `max-lifetime` wählen.

Für den User-Wechsel zählen drei Details der Klassen:

- `SecretFileCredentialsProvider` liest `username` und `password` aus dem Secret, nicht nur das Passwort. Wer eine ältere Variante ohne Username übernommen hat, muss sie aktualisieren.
- Der Provider liest beide Dateien über den aufgelösten `..data`-Symlink. Ohne diesen Schritt könnte der Provider zwischen den zwei Lesevorgängen den neuen User mit dem alten Passwort kombinieren.
- `DbCredentialsEndpoint` liefert `username` mit, darauf wartet das Skript:
  ```json
  { "version": "20261010091500", "username": "pool_b", "active": 1, "idle": 9, "total": 10, "waiting": 0 }
  ```

## Schritt 2: Datenbank

Zwei User mit denselben Rechten anlegen. MySQL:

```sql
CREATE USER IF NOT EXISTS 'pool_a'@'%' IDENTIFIED BY '<passwort-a>';
CREATE USER IF NOT EXISTS 'pool_b'@'%' IDENTIFIED BY '<passwort-b>';
GRANT ALL PRIVILEGES ON `pool`.* TO 'pool_a'@'%';
GRANT ALL PRIVILEGES ON `pool`.* TO 'pool_b'@'%';
```

`ALL PRIVILEGES` stammt aus der Demo ([db.sh](db.sh)). In einer bestehenden Anwendung die Grants des bisherigen Users übernehmen (`SHOW GRANTS FOR '<alter-user>'@'%';`) und an beide User vergeben.

Worauf man achten muss:

- **Gleiche Rechte.** Jeder neue Grant muss an beide User gehen. Fehlt einer bei `pool_b`, merkt man das erst nach dem nächsten Wechsel. Ich würde beide User einer gemeinsamen Rolle zuordnen und Grants nur an die Rolle vergeben.
- **Objekt-Eigentümer.** In MySQL gehören Tabellen der Datenbank, nicht dem User. In PostgreSQL gehören sie dem User, der sie anlegt. Dort beide User Mitglied einer gemeinsamen Owner-Rolle machen und Migrationen (Flyway, Liquibase) mit `SET ROLE` auf diese Rolle laufen lassen. Sonst kann `pool_b` keine Tabellen ändern, die `pool_a` angelegt hat.
- **Verbindungslimits.** Während des Wechsels halten beide User Verbindungen. Ein Limit pro User (`MAX_USER_CONNECTIONS`) muss für die volle Poolgröße aller Pods reichen.
- **Auditing.** DB-Logs zeigen je nach Phase `pool_a` oder `pool_b`. Auswertungen, die nach Username filtern, auf beide anpassen.

## Schritt 3: Kubernetes

Secret und Deployment wie in [change.md, Schritt 4](change.md#schritt-4-kubernetes): Secret mit `username`, `password`, `version`, als Volume ohne `subPath` gemountet, `lookup` im Helm-Template.

Bei der Migration eines bestehenden Systems darf der aktive User zunächst der bisherige bleiben (in der Demo `pool`). Der erste Lauf von `change-user.sh` wechselt dann auf `pool_a`, danach immer zwischen `pool_a` und `pool_b`. Den alten User erst sperren oder löschen, wenn nach dem ersten Wechsel `max-lifetime` abgelaufen ist.

## Schritt 4: Skript anpassen

[change-user.sh](change-user.sh) ist auf die lokale Demo zugeschnitten:

| Stelle | Demo | Anpassen auf |
|--------|------|--------------|
| `APP`, `NAMESPACE`, `SECRET` | `pool`, `pool`, `pool-db` | Name der Anwendung, Namespace, Secret |
| `PASSWORDS` | fest im Skript, gleiche Werte wie in `db.sh` | aus einem eigenen Secret oder Vault lesen, nicht im Skript speichern |
| `can_login()` | `docker exec` in den Container `mysql-pool` | DB-Client gegen den echten DB-Host (`mysql`, `psql`, `sqlcmd`) |
| `pod_synced()` | `curl localhost:8080/actuator/dbcredentials`, Container `-c "$APP"` | Management-Port und Container-Name |
| Pod-Selector | `-l app="$APP"` | Label des Deployments |
| User-Namen | `${APP}_a` / `${APP}_b` | eigene Namen |

Für `PASSWORDS` bietet sich ein zweites Secret an, das die App nicht mountet, z. B. `pool-db-users` mit den Schlüsseln `pool_a` und `pool_b`. Das Skript liest dann das Passwort des Ziel-Users von dort.

Aufruf:

```bash
./change-user.sh
```

Was das Skript absichert:

- **Login vorab prüfen.** Kann sich der Ziel-User nicht anmelden, bricht das Skript ab, bevor das Secret geändert wird.
- **Atomarer Secret-Patch.** `username`, `password` und `version` gehen in einem Patch ins Secret. kubelet schreibt sie als einen Stand ins Volume.
- **Fortsetzen nach Abbruch.** Der Ziel-User liegt vorab als `pending-username` / `pending-version` im Secret. Ein erneuter Lauf setzt den Wechsel auf denselben User fort, statt zurückzuschalten.
- **Warten auf beide Werte.** Ein Pod gilt erst als umgestellt, wenn er neue `version` und neuen `username` meldet.
- **Gegenseitiger Schutz.** Läuft gerade eine unterbrochene Passwortrotation (`pending-password`), bricht `change-user.sh` ab, und umgekehrt.

## Passwörter rotieren mit zwei Usern

`change-user.sh` wechselt nur den aktiven User, die Passwörter bleiben fest. Für eine echte Rotation ohne Dual Password das Passwort des inaktiven Users ändern und dann auf ihn wechseln:

```
1. ./change-user.sh                                aktiv: pool_b, inaktiv: pool_a
2. max-lifetime abwarten                           keine Verbindung nutzt mehr pool_a
3. ALTER USER pool_a IDENTIFIED BY '<neu>';        als root oder DBA
4. Passwort von pool_a im Passwort-Secret ablegen
5. ./change-user.sh                                aktiv: pool_a mit neuem Passwort
```

Schritt 2 darf nicht fehlen. Das Passwort von `pool_a` darf sich erst ändern, wenn kein Pod mehr mit `pool_a` verbindet. Offene Sessions überleben eine Passwortänderung. Baut ein Pod aber genau dann eine neue Verbindung mit `pool_a` auf, bekommt er einen Login-Fehler. Das Skript automatisiert diese Schritte noch nicht.

## Testen

1. Anwendung deployen, `/actuator/dbcredentials` muss `version` ungleich `none` und den aktuellen `username` zeigen.
2. Dauerlast starten (`./test.sh`).
3. `./change-user.sh` ausführen. Die Last darf keine Fehler zeigen.
4. Im Log jedes Pods erscheint `Neue Verbindungen nutzen DB-User pool_a, Secret-Version ...`.
5. In der DB nach `max-lifetime` prüfen, dass nur noch der neue User verbunden ist:
   ```sql
   SELECT user, COUNT(*) FROM information_schema.processlist GROUP BY user;
   ```

## Checkliste

- [ ] Anwendungsteil aus [change.md](change.md) umgesetzt, Provider liest auch `username`
- [ ] zwei User mit identischen Grants, am besten über eine gemeinsame Rolle
- [ ] bei PostgreSQL: gemeinsame Owner-Rolle für Tabellen
- [ ] Verbindungslimits reichen für beide User gleichzeitig
- [ ] Passwörter der beiden User nicht im Skript, sondern in einem eigenen Secret
- [ ] Skript auf DB-Client, Namespace, Labels und Port angepasst
- [ ] alter Einzel-User erst nach dem ersten Wechsel plus `max-lifetime` sperren

## Einschränkungen

- Offene Verbindungen des alten Users laufen bis `max-lifetime` weiter. Soll der alte User sofort raus, zusätzlich `HikariPoolMXBean.softEvictConnections()` aufrufen oder die Pods neu starten.
- Zwei User verdoppeln den Pflegeaufwand für Grants. Abweichende Rechte merkt man erst nach dem Wechsel.
- Die Env-Variablen `SPRING_DATASOURCE_USERNAME` / `SPRING_DATASOURCE_PASSWORD` zeigen nach einem Wechsel den Stand beim Pod-Start. Sie dienen nur als Fallback.
