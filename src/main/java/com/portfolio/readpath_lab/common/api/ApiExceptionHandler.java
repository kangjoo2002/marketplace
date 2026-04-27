package com.portfolio.readpath_lab.common.api;

import java.util.List;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.validation.BindException;
import org.springframework.validation.FieldError;
import org.springframework.web.bind.MethodArgumentNotValidException;
import org.springframework.web.bind.annotation.ExceptionHandler;
import org.springframework.web.bind.annotation.RestControllerAdvice;
import org.springframework.web.method.annotation.MethodArgumentTypeMismatchException;

@RestControllerAdvice
public class ApiExceptionHandler {

	@ExceptionHandler(MethodArgumentNotValidException.class)
	public ResponseEntity<ApiErrorResponse> handleMethodArgumentNotValid(MethodArgumentNotValidException exception) {
		return badRequest(bindingErrors(exception));
	}

	@ExceptionHandler(BindException.class)
	public ResponseEntity<ApiErrorResponse> handleBind(BindException exception) {
		return badRequest(bindingErrors(exception));
	}

	@ExceptionHandler(MethodArgumentTypeMismatchException.class)
	public ResponseEntity<ApiErrorResponse> handleMethodArgumentTypeMismatch(MethodArgumentTypeMismatchException exception) {
		String fieldName = exception.getName();
		String requiredType = exception.getRequiredType() == null
				? "supported type"
				: exception.getRequiredType().getSimpleName();

		return badRequest(List.of(fieldName + " must be a valid " + requiredType));
	}

	private static List<String> bindingErrors(BindException exception) {
		return exception.getBindingResult()
				.getAllErrors()
				.stream()
				.map(error -> {
					if (error instanceof FieldError fieldError) {
						return fieldError.getField() + ": " + fieldError.getDefaultMessage();
					}
					return error.getDefaultMessage();
				})
				.toList();
	}

	private static ResponseEntity<ApiErrorResponse> badRequest(List<String> errors) {
		return ResponseEntity
				.status(HttpStatus.BAD_REQUEST)
				.body(new ApiErrorResponse("Invalid request", errors));
	}
}
