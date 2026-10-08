package com.example.pool.credentials;

import java.nio.file.Path;

import org.springframework.beans.factory.annotation.Value;
import org.springframework.beans.factory.config.BeanPostProcessor;
import org.springframework.stereotype.Component;

import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.util.Credentials;

/**
 * Hängt den {@link SecretFileCredentialsProvider} an jede {@link HikariDataSource}, sobald
 * {@code app.db-credentials.dir} gesetzt ist. Muss vor dem Start des Pools passieren, danach ist
 * die Hikari-Konfiguration versiegelt. Der Pool startet erst beim ersten
 * {@code getConnection()}, also nach der Bean-Initialisierung.
 */
@Component
public class SecretFileCredentialsInstaller implements BeanPostProcessor {

	private final Path dir;

	public SecretFileCredentialsInstaller(@Value("${app.db-credentials.dir:}") String dir) {
		this.dir = dir.isBlank() ? null : Path.of(dir);
	}

	@Override
	public Object postProcessAfterInitialization(Object bean, String beanName) {
		if (dir != null && bean instanceof HikariDataSource dataSource) {
			dataSource.setCredentialsProvider(new SecretFileCredentialsProvider(dir,
					Credentials.of(dataSource.getUsername(), dataSource.getPassword())));
		}
		return bean;
	}

}
