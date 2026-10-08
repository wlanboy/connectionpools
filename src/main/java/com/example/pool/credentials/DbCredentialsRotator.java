package com.example.pool.credentials;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.SQLException;
import java.time.Instant;

import javax.sql.DataSource;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;
import com.zaxxer.hikari.util.Credentials;

/**
 * Überwacht das gemountete Kubernetes-Secret und tauscht das DB-Passwort im laufenden
 * Hikari-Pool aus, ohne dass ein Request fehlschlägt.
 * <p>
 * Ablauf bei geändertem Passwort:
 * <ol>
 * <li>Neues Passwort mit einer separaten Verbindung testen. Schlägt das fehl, bleibt der Pool
 * unverändert und es wird beim nächsten Poll erneut versucht.</li>
 * <li>Credentials im Pool austauschen. Hikari liest sie bei jeder neuen Verbindung.</li>
 * <li>Soft-Evict: freie Verbindungen werden sofort geschlossen, belegte erst bei der Rückgabe
 * an den Pool. Laufende Requests arbeiten also mit ihrer Verbindung zu Ende.</li>
 * </ol>
 * Voraussetzung: Die DB akzeptiert während der Umstellung altes und neues Passwort (MySQL
 * {@code RETAIN CURRENT PASSWORD}).
 */
@Component
public class DbCredentialsRotator {

	private static final Logger log = LoggerFactory.getLogger(DbCredentialsRotator.class);

	private final HikariDataSource dataSource;

	private final Path dir;

	private volatile String version = "initial";

	private volatile Instant rotatedAt;

	public DbCredentialsRotator(DataSource dataSource, @Value("${app.db-credentials.dir:}") String dir)
			throws SQLException {
		this.dataSource = dataSource.unwrap(HikariDataSource.class);
		this.dir = dir.isBlank() ? null : Path.of(dir);
	}

	@Scheduled(fixedDelayString = "${app.db-credentials.poll-interval:5s}")
	public synchronized void checkForNewPassword() {
		if (dir == null || !Files.isReadable(dir.resolve("password"))) {
			return;
		}
		String password;
		String newVersion;
		try {
			password = Files.readString(dir.resolve("password")).strip();
			Path versionFile = dir.resolve("version");
			newVersion = Files.isReadable(versionFile) ? Files.readString(versionFile).strip() : "unknown";
		}
		catch (IOException ex) {
			log.warn("Secret in {} nicht lesbar: {}", dir, ex.getMessage());
			return;
		}

		Credentials current = dataSource.getCredentials();
		if (password.equals(current.getPassword())) {
			version = newVersion;
			return;
		}

		try (Connection probe = DriverManager.getConnection(dataSource.getJdbcUrl(), current.getUsername(),
				password)) {
			probe.isValid(5);
		}
		catch (SQLException ex) {
			log.warn("Neues DB-Passwort (Version {}) wird noch nicht akzeptiert: {}", newVersion, ex.getMessage());
			return;
		}

		dataSource.getHikariConfigMXBean().setCredentials(Credentials.of(current.getUsername(), password));
		HikariPoolMXBean pool = dataSource.getHikariPoolMXBean();
		if (pool != null) {
			pool.softEvictConnections();
		}
		version = newVersion;
		rotatedAt = Instant.now();
		log.info("DB-Passwort auf Version {} umgestellt, alte Verbindungen werden nach Rückgabe geschlossen",
				newVersion);
	}

	public String version() {
		return version;
	}

	public Instant rotatedAt() {
		return rotatedAt;
	}

	public HikariPoolMXBean pool() {
		return dataSource.getHikariPoolMXBean();
	}

}
