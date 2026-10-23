# Passwortrotation ohne Downtime mit Oracle Database

Die Demo läuft gegen MySQL. Diese Anleitung beschreibt, was sich ändert, wenn die Anwendung mit Oracle Database arbeitet. Beide Verfahren aus [change.md](change.md) und [switch.md](switch.md) lassen sich übertragen:

- **Gradual Database Password Rollover** ist das Oracle-Gegenstück zu MySQL Dual Password. Nach einem Passwortwechsel gelten altes und neues Passwort eine Zeit lang parallel.
- **Zwei User im Wechsel** funktioniert ohne DB-Feature. In Oracle ist dabei zu beachten, dass jeder User ein eigenes Schema ist.

Der Java-Code für den Pool bleibt gleich. `SecretFileCredentialsProvider`, `SecretFileCredentialsInstaller` und `DbCredentialsEndpoint` kennen die Datenbank nicht. Anzupassen sind Treiber, JDBC-URL, Schema, Datenbank-Setup, Kubernetes-Service und die SQL-Teile der Skripte.

## Welche Methode

| | MySQL Dual Password ([change.md](change.md)) | Oracle Password Rollover | Zwei User ([switch.md](switch.md)) |
|---|---|---|---|
| Version | MySQL ab 8.0.14 | Oracle 21c, 23ai, 19c ab RU 19.12 | jede Version |
| Altes Passwort gilt | bis `DISCARD OLD PASSWORD` | bis `EXPIRE PASSWORD ROLLOVER PERIOD` oder bis `PASSWORD_ROLLOVER_TIME` abläuft | dauerhaft (zweiter User) |
| Einrichtung | Privileg `APPLICATION_PASSWORD_ADMIN` | Profil mit `PASSWORD_ROLLOVER_TIME` | zwei User, gemeinsames Schema, Rolle |
| Tabellen gehören | der Datenbank | dem App-User (sein Schema) | einem eigenen Schema-Owner |

Ich würde bei Oracle ab 19.12 den Rollover nehmen. Er braucht nur ein Profil, und Tabellen bleiben im Schema des App-Users. Der A/B-Wechsel lohnt sich bei älteren Versionen oder wenn ohnehin ein getrennter Schema-Owner gewünscht ist.

## Was sich gegenüber MySQL ändert

- **Der Rollover endet von selbst.** MySQL behält das alte Passwort, bis jemand `DISCARD OLD PASSWORD` ausführt. Oracle verwirft es spätestens nach `PASSWORD_ROLLOVER_TIME`. Bricht `change-password.sh` ab und läuft nicht rechtzeitig erneut, bauen Pods mit dem alten Passwort keine neuen Verbindungen mehr auf.
- **Ein zweiter Wechsel im Rollover verwirft das mittlere Passwort.** Wird innerhalb der Rollover-Phase erneut geändert (p1 → p2 → p3), gelten nur noch p1 und p3. Pods, die schon auf p2 stehen, verlieren den Login. Die Endzeit der Phase verschiebt sich dabei nicht. Eine neue Rotation darf also erst starten, wenn die vorige Phase beendet ist.
- **User und Schema sind dasselbe.** Tabellen, die `pool` anlegt, liegen im Schema `POOL`. Für den Rollover ist das egal, für den A/B-Wechsel nicht, siehe [Zwei User im Wechsel](#zwei-user-im-wechsel).
- **Usernamen sind Großbuchstaben.** `pool` ohne Anführungszeichen ist der User `POOL`. Im Secret und im Skript den Namen nie in `"..."` setzen, sonst sucht Oracle einen User `pool` in Kleinbuchstaben. In Data-Dictionary-Abfragen `'POOL'` schreiben.
- **Passwörter in Anführungszeichen.** Ohne `"..."` muss ein Passwort mit einem Buchstaben beginnen. Das Skript quotet deshalb immer. Ein `"` im Passwort selbst erlaubt Oracle nicht.
- **Client ist `sqlplus` statt `mysql`.** Kein `MYSQL_PWD`, die Zugangsdaten gehen per `CONNECT` über stdin.

## Voraussetzungen

- Alles aus [change.md](change.md#voraussetzungen) außer MySQL: HikariCP ab 6.x, Actuator, `curl` im Image, Rechte für Secret und Pods.
- **Oracle 21c, 23ai oder 19c ab Release Update 19.12** für den Rollover. Die Version zeigt `SELECT banner_full FROM v$version;`.
- **Oracle 23ai für das Schema unten** (`CREATE TABLE IF NOT EXISTS`, `BOOLEAN`). Bei 19c/21c siehe [Schritt 1](#schritt-1-anwendung).
- **`sqlplus` auf dem Rechner, der das Skript ausführt**, mit Netzwerkzugang zu `DB_HOST:DB_PORT`.

Instant Client unter Ubuntu: Die ZIPs *Basic* und *SQL\*Plus* von oracle.com laden (nicht in den Ubuntu-Paketquellen), nach `/opt/oracle` entpacken. Ab Ubuntu 24.04 heißt `libaio` anders, als Instant Client erwartet:

```bash
sudo apt install -y libaio1t64 jq openssl
sudo ln -sf /usr/lib/x86_64-linux-gnu/libaio.so.1t64 /usr/lib/x86_64-linux-gnu/libaio.so.1
export PATH=/opt/oracle/instantclient_23_9:$PATH        # Verzeichnis anpassen
export LD_LIBRARY_PATH=/opt/oracle/instantclient_23_9
sqlplus -v
```

Alternativ SQLcl (`sql`), braucht nur Java. Die Skript-Snippets unten funktionieren mit `sql -S /nolog` genauso.

## Schritt 1: Anwendung

### Treiber

Im `pom.xml` `mysql-connector-j` durch den Oracle-Treiber ersetzen. Die Version verwaltet Spring Boot:

```xml
<dependency>
    <groupId>com.oracle.database.jdbc</groupId>
    <artifactId>ojdbc17</artifactId>
    <scope>runtime</scope>
</dependency>
```

### Datasource

```properties
spring.datasource.url=jdbc:oracle:thin:@//localhost:1521/FREEPDB1
spring.datasource.username=pool
spring.datasource.password=poolsecret
spring.sql.init.schema-locations=classpath:schema-oracle.sql
```

`FREEPDB1` ist der Service-Name der PDB im Container unten. Den Parameter `connectionTimeZone=SERVER` aus der MySQL-URL gibt es bei Oracle nicht. Die Hikari-Werte bleiben unverändert, auch `max-lifetime` gilt wie bei MySQL: Oracle prüft das Passwort nur beim Login, offene Sessions überleben Passwortwechsel und Rollover-Ende.

### Schema

`schema.sql` ist MySQL-Syntax (`AUTO_INCREMENT`). Für Oracle eine eigene Datei `src/main/resources/schema-oracle.sql` anlegen:

```sql
CREATE TABLE IF NOT EXISTS message (
    id         NUMBER(19)     GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    created_at TIMESTAMP(3)   DEFAULT SYSTIMESTAMP NOT NULL,
    text       VARCHAR2(1000) NOT NULL,
    done       BOOLEAN        DEFAULT FALSE NOT NULL
);
```

`DEFAULT` muss in Oracle vor `NOT NULL` stehen. Bei 19c/21c gibt es weder `IF NOT EXISTS` noch `BOOLEAN`: `done NUMBER(1)` verwenden und `spring.sql.init.continue-on-error=true` setzen, damit der zweite Start nicht an `ORA-00955` scheitert. Besser ist dort eine Migration mit Flyway oder Liquibase.

`MessageRepository.create()` übergibt den Spaltennamen `"id"` an `update(keyHolder, "id")`. Das muss bei Oracle so bleiben. Ohne Spaltennamen liefert der Treiber eine ROWID statt des Schlüssels.

## Schritt 2: Datenbank

### Container (Demo)

Statt `db.sh` mit MySQL ein Oracle Database Free als Container. Das Image `gvenzl/oracle-free` legt den App-User beim ersten Start in `FREEPDB1` an:

```bash
docker run -d --name oracle-pool -p 1521:1521 \
  -e ORACLE_PASSWORD=rootsecret \
  -e APP_USER=pool -e APP_USER_PASSWORD=poolsecret \
  -v oracle-pool-data:/opt/oracle/oradata \
  gvenzl/oracle-free:23-slim
docker exec oracle-pool healthcheck.sh && echo bereit
```

`ORACLE_PASSWORD` gilt für `SYS` und `SYSTEM`. Der erste Start dauert ein bis zwei Minuten.

### Profil mit Rollover

Einmalig als `SYSTEM` in der PDB:

```sql
CREATE PROFILE app_rollover LIMIT PASSWORD_ROLLOVER_TIME 1;
ALTER USER pool PROFILE app_rollover;
```

`PASSWORD_ROLLOVER_TIME` steht in Tagen, `1` ist ein Tag, `1/24` eine Stunde. Erlaubt sind 1 Stunde bis 60 Tage, höchstens aber der kleinere Wert von `PASSWORD_LIFE_TIME` und `PASSWORD_GRACE_TIME` im Profil. Nicht angegebene Limits übernimmt das Profil aus `DEFAULT`.

Die Dauer ist ein Kompromiss. Sie muss für den ganzen Lauf von `change-password.sh` reichen und für einen erneuten Lauf nach einem Abbruch. Läuft das Skript durch, beendet Schritt 4 die Phase ohnehin vorzeitig. Ein Tag lässt Zeit für einen Abbruch über Nacht, eine Stunde begrenzt, wie lange ein abgelöstes Passwort noch gilt.

Worauf man achten muss:

- **Keine administrativen Privilegien.** Einem User mit Rollover-Profil lassen sich `SYSDBA`, `SYSOPER` und Co. nicht vergeben, und für administrative User greift der Rollover nicht. Für einen App-User sollte das ohnehin so sein.
- **Kein Privileg für den eigenen Wechsel.** Seinen eigenen Passwortwechsel darf jeder User ohne `ALTER USER`-Privileg ausführen. Mit `REPLACE` prüft Oracle dabei das alte Passwort. Ist eine `PASSWORD_VERIFY_FUNCTION` aktiv, ist `REPLACE` Pflicht und das neue Passwort muss deren Regeln erfüllen.
- **Rollover vorzeitig beenden.** Ob der App-User `EXPIRE PASSWORD ROLLOVER PERIOD` am eigenen Account ohne `ALTER USER`-Privileg ausführen darf, beschreibt die Oracle-Doku nicht eindeutig. Vorab testen. Klappt es nicht, Schritt 4 als DBA ausführen oder die Phase auslaufen lassen.
- **Wiederverwendung.** `PASSWORD_REUSE_TIME` und `PASSWORD_REUSE_MAX` im Profil bestimmen, ob ein [Rollback](#rollback) auf das alte Passwort möglich ist. Stehen beide auf `UNLIMITED`, erlaubt Oracle die Wiederverwendung.

## Schritt 3: Kubernetes

Secret, Volume und `lookup` bleiben wie in [change.md, Schritt 4](change.md#schritt-4-kubernetes). Im Chart ändern sich nur die DB-Teile:

| Stelle | MySQL | Oracle |
|---|---|---|
| `config.env` | `DB_PORT=3306` | `DB_PORT=1521`, zusätzlich `ORACLE_SERVICE=FREEPDB1` |
| `values.yaml`, `database` | `port: 3306`, `name: pool` | `port: 1521`, `name: FREEPDB1` (Service-Name) |
| `deployment.yaml`, `SPRING_DATASOURCE_URL` | `jdbc:mysql://mysql:<port>/<name>?...` | `jdbc:oracle:thin:@//oracle:<port>/<name>` |
| `deployment.yaml`, Schema | `schema.sql` | Env `SPRING_SQL_INIT_SCHEMA_LOCATIONS=classpath:schema-oracle.sql` |
| `mysql-service.yaml` | Service `mysql`, Port-Name `tcp-mysql` | Service `oracle`, Port-Name `tcp-oracle` |

Oracle Net ist anders als MySQL client-first, Istios Protocol Sniffing würde also nicht hängen. Den Port trotzdem als `tcp-` benennen, dann versucht Istio gar nicht erst zu raten. Bei RAC mit SCAN-Listener leitet der Listener Clients auf andere Adressen um. Dann müssen Service und EndpointSlice auch diese Adressen abdecken, sonst blockiert die Mesh-Policy die Umleitung.

## Schritt 4: change-password.sh für Oracle

Ablauf und Absicherungen bleiben wie in [change.md, Schritt 5](change.md#schritt-5-rotationsskript-anpassen). Es kommen zwei Prüfungen dazu, weil der Rollover zeitlich begrenzt ist:

```
change-password.sh (Oracle)
  0. k8s:     neues Passwort als pending-password im Secret ablegen
     Oracle:  Profil hat PASSWORD_ROLLOVER_TIME > 0?          sonst Abbruch
     Oracle:  keine Rollover-Phase aktiv (außer beim Fortsetzen)?  sonst Abbruch
  1. Oracle:  ALTER USER pool IDENTIFIED BY "<neu>" REPLACE "<alt>"  → alt + neu gültig
  2. k8s:     Secret patchen (password + version), Pods annotieren
  3. Pods:    kubelet schreibt die Datei, Skript pollt /actuator/dbcredentials
  4. Oracle:  ALTER USER pool EXPIRE PASSWORD ROLLOVER PERIOD        → nur noch neu gültig
```

Die Prüfung auf das Profil ist Pflicht. Fehlt der Rollover, macht `ALTER USER ... IDENTIFIED BY` einen harten Wechsel: Das alte Passwort ist sofort ungültig, und bis kubelet das Secret in die Pods geschrieben hat, scheitert jeder neue Login.

```
          Oracle akzeptiert              Secret / Pods         neue Verbindungen
Start     alt                            alt                   alt
Schritt 1 alt + neu (Rollover läuft)     alt                   alt
Schritt 2 alt + neu                      neu (kubelet-Sync)    alt → neu
Schritt 3 alt + neu                      neu, bestätigt        neu
Schritt 4 neu                            neu                   neu
```

### SQL-Zugang

`mysql_as()`, `can_login()` und `sql_escape()` durch diese Funktionen ersetzen. `printf` ist ein Bash-Builtin, das Passwort landet also nur auf stdin von `sqlplus`, nicht in der Prozessliste:

```bash
ORACLE_SERVICE=${ORACLE_SERVICE:-FREEPDB1}

# SQL von stdin als App-User mit dem übergebenen Passwort ausführen
sql_as() {
  { printf 'WHENEVER SQLERROR EXIT FAILURE\nSET HEADING OFF FEEDBACK OFF PAGESIZE 0\n'
    printf 'CONNECT %s/"%s"@//%s:%s/%s\n' "$DB_USER" "$1" "$DB_HOST" "$DB_PORT" "$ORACLE_SERVICE"
    cat
    printf 'EXIT\n'
  } | sqlplus -s /nolog
}

can_login() {
  sql_as "$1" <<<"SELECT 'LOGIN_OK' FROM dual;" 2>/dev/null | grep -q LOGIN_OK
}

[[ $NEW_PASSWORD == *'"'* ]] && { echo 'Passwort darf kein " enthalten.' >&2; exit 1; }
```

`can_login()` wertet die Ausgabe aus, nicht den Exit-Code. So ist das Ergebnis eindeutig, egal ob `sqlplus` nach einem fehlgeschlagenen `CONNECT` abbricht oder mit `SP2-0640: Not connected` weiterläuft.

### Prüfungen vor Schritt 1

Beide Abfragen gehen auf Views des eigenen Users, ein DBA ist nicht nötig:

```bash
ROLLOVER=$(sql_as "$CURRENT_PASSWORD" <<<"SELECT limit FROM user_password_limits WHERE resource_name = 'PASSWORD_ROLLOVER_TIME';")
STATUS=$(sql_as "$CURRENT_PASSWORD" <<<"SELECT account_status FROM user_users;")

if [[ -z $ROLLOVER || $ROLLOVER =~ ^[[:space:]]*(0|UNLIMITED)?[[:space:]]*$ ]]; then
  echo "Profil von $DB_USER hat kein PASSWORD_ROLLOVER_TIME, Abbruch vor jeder Änderung." >&2
  exit 1
fi
if [[ -z $PENDING_PASSWORD && $STATUS == *ROLLOVER* ]]; then
  echo "Rollover-Phase von $DB_USER läuft noch ($STATUS). Erst beenden oder ablaufen lassen." >&2
  exit 1
fi
```

Während der Phase steht in `account_status` z. B. `OPEN & IN ROLLOVER`. Beim Fortsetzen einer unterbrochenen Rotation ist das erwartet, sonst nicht: Ein neuer Wechsel mitten in einer fremden Phase würde das Passwort ungültig machen, das die Pods gerade nutzen. Beim Fortsetzen meldet sich das Skript mit dem neuen Passwort an, falls das aktuelle aus dem Secret nicht mehr gilt.

### Schritt 1 und 4

```bash
# 1. Neues Passwort setzen, das bisherige bleibt bis zum Ende der Rollover-Phase gültig
sql_as "$CURRENT_PASSWORD" <<SQL
ALTER USER $DB_USER IDENTIFIED BY "$NEW_PASSWORD" REPLACE "$CURRENT_PASSWORD";
SQL

# 4. Rollover-Phase beenden, nur noch das neue Passwort gilt
sql_as "$NEW_PASSWORD" <<SQL
ALTER USER $DB_USER EXPIRE PASSWORD ROLLOVER PERIOD;
SQL
```

Die Logik drumherum bleibt: Klappt der Login mit dem neuen Passwort schon, Schritt 1 überspringen. Klappt weder neu noch alt, abbrechen. Scheitert Schritt 4 an fehlenden Rechten, ist die Rotation trotzdem korrekt. Das Skript sollte dann nur warnen, dass das alte Passwort bis zum Ende von `PASSWORD_ROLLOVER_TIME` gültig bleibt, und `pending-*` trotzdem entfernen.

`TIMEOUT` im Skript (180 s) muss deutlich kleiner sein als `PASSWORD_ROLLOVER_TIME`. Bei einem Tag ist das kein Thema, bei `1/24` sollten auch langsame Rollouts in die Stunde passen.

## Zwei User im Wechsel

`change-user.sh` ändert in der DB nichts und funktioniert mit Oracle, sobald `can_login()` auf `sqlplus` umgestellt ist (Funktion oben, mit dem User als zusätzlichem Parameter statt `$DB_USER`). Der Aufwand liegt im Datenbank-Setup: Die beiden User dürfen die Tabellen nicht selbst besitzen, sonst sieht `pool_b` nach dem Wechsel ein leeres Schema.

### Gemeinsames Schema

Als `SYSTEM` in der PDB (Oracle 23ai):

```sql
-- Schema ohne Login, besitzt die Tabellen
CREATE USER pool_owner NO AUTHENTICATION;
ALTER USER pool_owner QUOTA UNLIMITED ON users;

-- Rechte auf das ganze Schema über eine Rolle, auch für später angelegte Tabellen
CREATE ROLE pool_app;
GRANT SELECT ANY TABLE, INSERT ANY TABLE, UPDATE ANY TABLE, DELETE ANY TABLE
  ON SCHEMA pool_owner TO pool_app;

CREATE USER pool_a IDENTIFIED BY "poolsecret_a";
CREATE USER pool_b IDENTIFIED BY "poolsecret_b";
GRANT CREATE SESSION, pool_app TO pool_a, pool_b;
```

Schema-Privilegien (`ON SCHEMA`) gibt es ab 23ai. Bei 19c/21c Objektrechte pro Tabelle an die Rolle vergeben (`GRANT SELECT, INSERT, UPDATE, DELETE ON pool_owner.message TO pool_app;`) und bei jeder neuen Tabelle nachziehen.

In der Anwendung:

```properties
# Jede neue Verbindung arbeitet im Schema des Owners, ohne Präfix im SQL
spring.datasource.hikari.connection-init-sql=ALTER SESSION SET CURRENT_SCHEMA = POOL_OWNER
# Tabellen legt nicht die App an, pool_a/pool_b haben kein CREATE TABLE
spring.sql.init.mode=never
```

Im Chart als `SPRING_DATASOURCE_HIKARI_CONNECTIONINITSQL` und `SPRING_SQL_INIT_MODE=never`. Die Tabellen legt ein DBA oder ein Migrationsjob im Schema `POOL_OWNER` an. Für Flyway oder Liquibase eignet sich ein Proxy-Login: `ALTER USER pool_owner GRANT CONNECT THROUGH <migrations-user>;`, dann verbindet sich das Tool als `<migrations-user>[pool_owner]`.

Worauf man achten muss:

- **Gleiche Rechte über die Rolle.** Grants nur an `pool_app` vergeben, nie direkt an `pool_a` oder `pool_b`. Dann können die beiden nicht auseinanderlaufen.
- **Verbindungslimits.** Während des Wechsels halten beide User Verbindungen. Ein `SESSIONS_PER_USER` im Profil muss für die volle Poolgröße aller Pods reichen.
- **Passwortablauf.** Das `DEFAULT`-Profil lässt Passwörter nach `PASSWORD_LIFE_TIME` ablaufen. Der inaktive User merkt das erst beim nächsten Wechsel, `can_login()` bricht dann ab. Für beide User ein Profil mit passender Laufzeit vergeben oder das Ablaufdatum überwachen (`dba_users.expiry_date`).
- **Rotation des inaktiven Users.** Wie in [switch.md](switch.md#passwörter-rotieren-mit-zwei-usern). Der Rollover ist hier nicht nötig, der inaktive User hat nach `max-lifetime` keine Verbindungen mehr.

## Testen

1. Anwendung deployen, `/actuator/dbcredentials` muss `version: initial` und den User zeigen.
2. Profil prüfen: `./change-password.sh` muss ohne Rollover-Profil vor Schritt 1 abbrechen. Das einmal bewusst ausprobieren.
3. Dauerlast starten (`./test.sh`), `./change-password.sh` ausführen. Die Last darf keine Fehler zeigen.
4. Während Schritt 3 in der DB prüfen, dass der Rollover läuft:
   ```sql
   SELECT username, account_status, profile FROM dba_users WHERE username = 'POOL';
   ```
5. Nach dem Lauf steht `account_status` wieder auf `OPEN`. Nach `max-lifetime` sind alle Verbindungen neu aufgebaut.
6. Für den A/B-Wechsel nach `max-lifetime` prüfen, dass nur noch der neue User verbunden ist:
   ```sql
   SELECT username, COUNT(*) FROM v$session WHERE username LIKE 'POOL%' GROUP BY username;
   ```

## Rollback

Es gilt dasselbe wie in [readme.md, Rollback](readme.md#rollback), mit einer Oracle-Besonderheit: `./change-password.sh '<altes-passwort>'` erst, wenn die Rollover-Phase der vorigen Rotation beendet ist. Andernfalls gelten danach das ursprüngliche und das neueste Passwort, also beide Male das alte, und das Passwort, mit dem die Pods gerade arbeiten, ist verworfen. Die Prüfung auf `account_status` im Skript fängt das ab.

Welche Clients mit dem User verbunden sind, zeigt `v$session` (braucht `SELECT_CATALOG_ROLE` oder DBA):

```sql
SELECT machine, program, COUNT(*) FROM v$session
WHERE username = 'POOL' GROUP BY machine, program;
```

Der Thin-Treiber meldet als `machine` den Hostnamen, in Kubernetes also den Pod-Namen. Jede andere Maschine ist ein Client, der die Rotation mitmachen muss. Wie bei MySQL fehlen Clients, die gerade nicht verbunden sind, z. B. ein täglicher Job.

Logins mit dem alten Passwort während der Phase lassen sich per Unified Auditing erkennen: Eine Audit-Policy auf `LOGON`, danach in `unified_audit_trail` die Spalte `authentication_type` auf `VERIFIER=12C-OLD` prüfen. Das ist nicht ganz zuverlässig, je nach Patchstand taucht der Eintrag auch bei fehlgeschlagenen Logins auf. Vorab in der eigenen Umgebung prüfen.

## Checkliste

- [ ] Oracle 21c/23ai oder 19c ab RU 19.12
- [ ] `ojdbc17` statt `mysql-connector-j`, JDBC-URL mit Service-Name
- [ ] `schema-oracle.sql` und `spring.sql.init.schema-locations` gesetzt
- [ ] Anwendungsteil aus [change.md](change.md) unverändert übernommen
- [ ] Profil mit `PASSWORD_ROLLOVER_TIME` am App-User, Dauer bewusst gewählt
- [ ] getestet, ob der App-User `EXPIRE PASSWORD ROLLOVER PERIOD` selbst ausführen darf
- [ ] Skript bricht ohne Rollover-Profil und bei laufender Phase ab
- [ ] Usernamen nie in Anführungszeichen, Passwörter immer
- [ ] Service `oracle` mit Port-Name `tcp-oracle`, Port 1521
- [ ] bei A/B: Schema-Owner ohne Login, Rechte über eine Rolle, `CURRENT_SCHEMA` per `connection-init-sql`

## Einschränkungen

- Der Rollover ist zeitlich begrenzt. Eine abgebrochene Rotation muss innerhalb von `PASSWORD_ROLLOVER_TIME` fortgesetzt werden, sonst verlieren Pods mit dem alten Passwort den Login für neue Verbindungen.
- Pro User läuft höchstens eine Rollover-Phase. Ein zweiter Wechsel darin verwirft das mittlere Passwort.
- Wie bei MySQL tauscht Hikari offene Verbindungen nicht aus. Muss ein kompromittiertes Passwort sofort raus, zusätzlich `HikariPoolMXBean.softEvictConnections()` aufrufen oder die Pods neu starten. Offene Sessions lassen sich in Oracle auch per `ALTER SYSTEM KILL SESSION` beenden, die Anwendung sieht dann aber Fehler auf diesen Verbindungen.
- Die Skripte im Projekt sprechen nur MySQL. Die Snippets oben zeigen die Oracle-Teile, ein lauffähiges `change-password.sh` für Oracle gibt es im Projekt noch nicht.
