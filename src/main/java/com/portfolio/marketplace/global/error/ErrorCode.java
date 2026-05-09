package com.portfolio.marketplace.global.error;

import org.springframework.http.HttpStatus;

public interface ErrorCode {

	String code();

	String message();

	HttpStatus status();
}
