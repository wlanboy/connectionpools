package com.example.pool;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

@SpringBootApplication
@EnableScheduling
public class PoolApplication {

	public static void main(String[] args) {
		SpringApplication.run(PoolApplication.class, args);
	}

}
