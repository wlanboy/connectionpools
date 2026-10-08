package com.example.pool.message;

import java.util.List;
import java.util.Optional;

import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.jdbc.support.GeneratedKeyHolder;
import org.springframework.stereotype.Repository;

@Repository
public class MessageRepository {

	private static final String SELECT = "SELECT id, created_at, text, done FROM message";

	private final JdbcClient jdbc;

	public MessageRepository(JdbcClient jdbc) {
		this.jdbc = jdbc;
	}

	public List<Message> findAll() {
		return jdbc.sql(SELECT + " ORDER BY created_at DESC, id DESC")
				.query(Message.class)
				.list();
	}

	public Optional<Message> findById(long id) {
		return jdbc.sql(SELECT + " WHERE id = ?")
				.param(id)
				.query(Message.class)
				.optional();
	}

	public Message create(String text) {
		var keyHolder = new GeneratedKeyHolder();
		jdbc.sql("INSERT INTO message (text) VALUES (?)")
				.param(text)
				.update(keyHolder, "id");
		return findById(keyHolder.getKey().longValue()).orElseThrow();
	}

	public boolean setDone(long id, boolean done) {
		return jdbc.sql("UPDATE message SET done = ? WHERE id = ?")
				.params(done, id)
				.update() > 0;
	}

	public boolean delete(long id) {
		return jdbc.sql("DELETE FROM message WHERE id = ?")
				.param(id)
				.update() > 0;
	}

}
