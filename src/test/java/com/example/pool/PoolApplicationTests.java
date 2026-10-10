package com.example.pool;

import org.junit.jupiter.api.Test;
import org.springframework.boot.test.context.SpringBootTest;

// H2 in-memory statt MySQL, damit der Test ohne laufende DB startet.
// Inline-Properties überschreiben ./application.properties im Projektverzeichnis.
@SpringBootTest(properties = {
		"spring.datasource.url=jdbc:h2:mem:pool;MODE=MySQL;DB_CLOSE_DELAY=-1",
		"spring.datasource.username=sa",
		"spring.datasource.password=" })
class PoolApplicationTests {

	@Test
	void contextLoads() {
	}

}
