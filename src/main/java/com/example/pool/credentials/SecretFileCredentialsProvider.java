package com.example.pool.credentials;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import com.zaxxer.hikari.HikariCredentialsProvider;
import com.zaxxer.hikari.util.Credentials;

/**
 * Liefert Hikari bei jedem neuen Verbindungsaufbau das Passwort aus dem gemounteten
 * Kubernetes-Secret. kubelet aktualisiert die Datei im laufenden Pod, neue Verbindungen nutzen
 * also automatisch das rotierte Passwort. Bestehende Verbindungen laufen bis zu ihrer
 * {@code maxLifetime} weiter.
 * <p>
 * Voraussetzung: Die DB akzeptiert während der Umstellung altes und neues Passwort (MySQL
 * {@code RETAIN CURRENT PASSWORD}), und das Secret wird erst nach der DB geändert.
 */
public class SecretFileCredentialsProvider implements HikariCredentialsProvider {

	private static final Logger log = LoggerFactory.getLogger(SecretFileCredentialsProvider.class);

	private final Path dir;

	private volatile Credentials lastKnown;

	/**
	 * @param dir Verzeichnis des Secret-Volumes mit den Dateien {@code password} und
	 * {@code version}
	 * @param initial Credentials aus der Konfiguration, falls die Datei nicht lesbar ist
	 */
	public SecretFileCredentialsProvider(Path dir, Credentials initial) {
		this.dir = dir;
		this.lastKnown = initial;
	}

	@Override
	public Credentials getCredentials() {
		try {
			String password = Files.readString(dir.resolve("password")).strip();
			if (!password.equals(lastKnown.getPassword())) {
				lastKnown = Credentials.of(lastKnown.getUsername(), password);
				log.info("Neue Verbindungen nutzen DB-Passwort-Version {}", version());
			}
		}
		catch (IOException ex) {
			log.warn("Secret in {} nicht lesbar, nutze letztes bekanntes Passwort: {}", dir, ex.getMessage());
		}
		return lastKnown;
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
