package com.portfolio.marketplace.productsearch.error;

import com.portfolio.marketplace.global.error.ErrorCode;
import org.springframework.http.HttpStatus;

public enum ProductSearchErrorCode implements ErrorCode {

	UNSUPPORTED_READ_PATH("PRODUCT_SEARCH_UNSUPPORTED_READ_PATH", "Unsupported product search read path", HttpStatus.BAD_REQUEST),
	OPENSEARCH_RESPONSE_MALFORMED("PRODUCT_SEARCH_OPENSEARCH_RESPONSE_MALFORMED", "OpenSearch response was malformed", HttpStatus.BAD_GATEWAY);

	private final String code;
	private final String message;
	private final HttpStatus status;

	ProductSearchErrorCode(String code, String message, HttpStatus status) {
		this.code = code;
		this.message = message;
		this.status = status;
	}

	@Override
	public String code() {
		return code;
	}

	@Override
	public String message() {
		return message;
	}

	@Override
	public HttpStatus status() {
		return status;
	}
}
