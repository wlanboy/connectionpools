package com.example.pool.credentials;

import java.time.Instant;

import org.springframework.boot.actuate.endpoint.annotation.Endpoint;
import org.springframework.boot.actuate.endpoint.annotation.ReadOperation;
import org.springframework.stereotype.Component;

import com.zaxxer.hikari.HikariPoolMXBean;

/**
 * {@code /actuator/dbcredentials}: aktive Secret-Version und Pool-Zustand. change-password.sh
 * wartet hierüber, bis jeder Pod umgestellt hat. Das Passwort selbst wird nie ausgegeben.
 */
@Component
@Endpoint(id = "dbcredentials")
public class DbCredentialsEndpoint {

	record Status(String version, Instant rotatedAt, int active, int idle, int total, int waiting) {
	}

	private final DbCredentialsRotator rotator;

	public DbCredentialsEndpoint(DbCredentialsRotator rotator) {
		this.rotator = rotator;
	}

	@ReadOperation
	public Status status() {
		HikariPoolMXBean pool = rotator.pool();
		if (pool == null) {
			return new Status(rotator.version(), rotator.rotatedAt(), 0, 0, 0, 0);
		}
		return new Status(rotator.version(), rotator.rotatedAt(), pool.getActiveConnections(),
				pool.getIdleConnections(), pool.getTotalConnections(), pool.getThreadsAwaitingConnection());
	}

}
