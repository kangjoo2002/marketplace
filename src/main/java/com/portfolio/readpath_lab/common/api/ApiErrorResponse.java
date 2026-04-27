package com.portfolio.readpath_lab.common.api;

import java.util.List;

public record ApiErrorResponse(
		String message,
		List<String> errors
) {
}
