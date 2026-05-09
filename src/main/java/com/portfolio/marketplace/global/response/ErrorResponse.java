package com.portfolio.marketplace.global.response;

import java.util.List;

public record ErrorResponse(
		String message,
		List<String> errors
) {
}



