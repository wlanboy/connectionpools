package com.example.pool.credentials;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.zaxxer.hikari.HikariCredentialsProvider;
import com.zaxxer.hikari.util.Credentials;

/**
 * Liefert Hikari bei jedem neuen Verbindungsaufbau Username und Passwort aus dem gemounteten
 * Kubernetes-Secret. kubelet aktualisiert die Dateien im laufenden Pod, neue Verbindungen nutzen
 * also automatisch die rotierten Credentials. Bestehende Verbindungen laufen bis zu ihrer
 * {@code maxLifetime} weiter.
 * <p>
 * Voraussetzung: Die DB akzeptiert die neuen Credentials, bevor das Secret geändert wird, und die
 * alten bleiben gültig, bis alle Pods umgestellt sind. Das leisten sowohl MySQL Dual Password
 * (change-password.sh) als auch zwei User im Wechsel (change-user.sh).
 */
public class SecretFileCredentialsProvider implements HikariCredentialsProvider {

	private static final Logger log = LoggerFactory.getLogger(SecretFileCredentialsProvider.class);

	private final Path dir;

	private volatile Credentials lastKnown;

	/**
	 * @param dir Verzeichnis des Secret-Volumes mit den Dateien {@code username},
	 * {@code password} und {@code version}
	 * @param initial Credentials aus der Konfiguration, falls die Datei nicht lesbar ist
	 */
	public SecretFileCredentialsProvider(Path dir, Credentials initial) {
		this.dir = dir;
		this.lastKnown = initial;
	}

	@Override
	public Credentials getCredentials() {
		try {
			Path data = snapshot();
			String username = Files.readString(data.resolve("username")).strip();
			String password = Files.readString(data.resolve("password")).strip();
			if (!username.equals(lastKnown.getUsername()) || !password.equals(lastKnown.getPassword())) {
				lastKnown = Credentials.of(username, password);
				log.info("Neue Verbindungen nutzen DB-User {}, Secret-Version {}", username, version());
			}
		}
		catch (IOException ex) {
			log.warn("Secret in {} nicht lesbar, nutze letztes bekanntes Passwort: {}", dir, ex.getMessage());
		}
		return lastKnown;
	}

	/**
	 * Verzeichnis eines konsistenten Secret-Stands. kubelet legt jeden Stand in einem eigenen
	 * Verzeichnis ab und tauscht den Symlink {@code ..data} atomar. Wer Username und Passwort
	 * nacheinander über die Symlinks im Volume liest, könnte sonst User A mit dem Passwort von
	 * User B kombinieren. Ohne {@code ..data} (lokales Verzeichnis) wird direkt gelesen.
	 */
	private Path snapshot() throws IOException {
		Path data = dir.resolve("..data");
		return Files.exists(data) ? data.toRealPath() : dir;
	}

	/**
	 * DB-User, mit dem der nächste Verbindungsaufbau arbeitet.
	 */
	public String username() {
		return getCredentials().getUsername();
	}

	/**
	 * Version des Secrets, mit der der nächste Verbindungsaufbau arbeitet.
	 */
	public String version() {
		try {
			return Files.readString(dir.resolve("version")).strip();
		}
		catch (IOException ex) {
			return "unknown";
		}
	}

}
