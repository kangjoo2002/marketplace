package com.portfolio.marketplace.global.error;

import com.portfolio.marketplace.global.response.ErrorResponse;
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
public class GlobalExceptionHandler {

	@ExceptionHandler(MethodArgumentNotValidException.class)
	public ResponseEntity<ErrorResponse> handleMethodArgumentNotValid(MethodArgumentNotValidException exception) {
		return badRequest(bindingErrors(exception));
	}

	@ExceptionHandler(BindException.class)
	public ResponseEntity<ErrorResponse> handleBind(BindException exception) {
		return badRequest(bindingErrors(exception));
	}

	@ExceptionHandler(MethodArgumentTypeMismatchException.class)
	public ResponseEntity<ErrorResponse> handleMethodArgumentTypeMismatch(MethodArgumentTypeMismatchException exception) {
		String fieldName = exception.getName();
		String requiredType = exception.getRequiredType() == null
				? "supported type"
				: exception.getRequiredType().getSimpleName();

		return badRequest(List.of(fieldName + " must be a valid " + requiredType));
	}

	@ExceptionHandler(BusinessException.class)
	public ResponseEntity<ErrorResponse> handleBusiness(BusinessException exception) {
		ErrorCode errorCode = exception.getErrorCode();
		return ResponseEntity
				.status(errorCode.status())
				.body(new ErrorResponse(errorCode.message(), List.of(errorCode.code())));
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

	private static ResponseEntity<ErrorResponse> badRequest(List<String> errors) {
		return ResponseEntity
				.status(HttpStatus.BAD_REQUEST)
				.body(new ErrorResponse("Invalid request", errors));
	}
}



