package com.example.pool.message;

import java.time.Instant;

public record Message(long id, Instant createdAt, String text, boolean done) {
}
