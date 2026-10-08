package com.example.pool.message;

import java.util.List;

import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.DeleteMapping;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PatchMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/messages")
public class MessageController {

	record CreateRequest(String text) {
	}

	record DoneRequest(boolean done) {
	}

	private final MessageRepository repository;

	public MessageController(MessageRepository repository) {
		this.repository = repository;
	}

	@GetMapping
	public List<Message> list() {
		return repository.findAll();
	}

	@PostMapping
	public ResponseEntity<Message> create(@RequestBody CreateRequest request) {
		if (request.text() == null || request.text().isBlank() || request.text().length() > 1000) {
			return ResponseEntity.badRequest().build();
		}
		return ResponseEntity.status(HttpStatus.CREATED).body(repository.create(request.text().strip()));
	}

	@PatchMapping("/{id}")
	public ResponseEntity<Message> setDone(@PathVariable long id, @RequestBody DoneRequest request) {
		if (!repository.setDone(id, request.done())) {
			return ResponseEntity.notFound().build();
		}
		return ResponseEntity.of(repository.findById(id));
	}

	@DeleteMapping("/{id}")
	public ResponseEntity<Void> delete(@PathVariable long id) {
		return repository.delete(id) ? ResponseEntity.noContent().build() : ResponseEntity.notFound().build();
	}

}
