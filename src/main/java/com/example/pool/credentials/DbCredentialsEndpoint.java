package com.example.pool.credentials;

import java.sql.SQLException;

import javax.sql.DataSource;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;

/**
 * {@code /actuator/dbcredentials}: Secret-Version, mit der neue Verbindungen aufgebaut werden,
 * und Pool-Zustand. change-password.sh wartet hierüber, bis kubelet das neue Secret in jeden Pod
 * geschrieben hat. Das Passwort selbst wird nie ausgegeben.
 */
@Component
@Endpoint(id = "dbcredentials")
public class DbCredentialsEndpoint {

	record Status(String version, int active, int idle, int total, int waiting) {
	}

	private final HikariDataSource dataSource;

	public DbCredentialsEndpoint(DataSource dataSource) throws SQLException {
		this.dataSource = dataSource.unwrap(HikariDataSource.class);
	}

	@ReadOperation
	public Status status() {
		String version = dataSource.getCredentialsProvider() instanceof SecretFileCredentialsProvider provider
				? provider.version() : "none";
		HikariPoolMXBean pool = dataSource.getHikariPoolMXBean();
		if (pool == null) {
			return new Status(version, 0, 0, 0, 0);
		}
		return new Status(version, pool.getActiveConnections(), pool.getIdleConnections(),
				pool.getTotalConnections(), pool.getThreadsAwaitingConnection());
	}

}
