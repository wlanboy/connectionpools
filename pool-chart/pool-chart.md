# pool-chart

Release `pool` im Namespace `pool`. Alle Befehle aus dem Projekt-Root ausführen.

## Installieren

Voraussetzung: Image liegt in `localhost:5001/pool`, Namespace `pool` existiert mit `istio-injection=enabled`. Beides erledigt `install.sh`.

```bash
kubectl create namespace pool --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace pool istio-injection=enabled --overwrite

helm install pool ./pool-chart -n pool \
  --set image.repository=localhost:5001/pool \
  --set-string image.tag=<TAG>
```

Beim ersten Install legt das Chart das Secret `pool-db` mit `database.username` / `database.password` aus `values.yaml` an.

## Aktualisieren

```bash
helm upgrade --install pool ./pool-chart -n pool \
  --set image.repository=localhost:5001/pool \
  --set-string image.tag=<NEUER_TAG>
kubectl rollout status deployment/pool -n pool --timeout=180s
```

`upgrade --install` funktioniert auch, wenn das Release noch nicht existiert. Nur ein neuer `image.tag` löst einen Rollout aus, mit `latest` sieht Helm keine Änderung. `--set-string` verhindert, dass ein reiner Zahlen-Tag wie `20261010120000` als Zahl gelesen wird.

Das Secret `pool-db` bleibt beim Upgrade unverändert (per `lookup`), ein rotiertes Passwort wird also nicht zurückgesetzt.

Zurück auf eine frühere Revision:

```bash
helm rollback pool <REVISION> -n pool
```

## Status

```bash
helm status pool -n pool                    # STATUS, Revision, letztes Deployment
helm status pool -n pool --show-resources   # erzeugte Objekte
helm history pool -n pool                   # alle Revisionen
helm get values pool -n pool                # per --set übergebene Werte
kubectl get pods -n pool                    # laufen die Pods wirklich?
```

## Deinstallieren

```bash
helm uninstall pool -n pool
kubectl delete namespace pool               # optional
```

Damit wird auch das Secret `pool-db` gelöscht. Ein neuer Install legt es wieder mit dem Passwort aus `values.yaml` an. Wurde vorher mit `change-password.sh` oder `change-user.sh` rotiert, passen die Zugangsdaten nicht mehr zur DB. Dann beim Install `--set database.username=<User> --set database.password=<Passwort>` mit den aktuellen Werten mitgeben oder die DB mit `db.sh` neu aufsetzen.
