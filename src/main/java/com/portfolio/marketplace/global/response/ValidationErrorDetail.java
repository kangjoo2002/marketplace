package com.portfolio.marketplace.global.response;

public record ValidationErrorDetail(
		String field,
		String message
) {
}
