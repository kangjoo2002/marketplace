package com.portfolio.readpath_lab.product.api;

public record ProductSearchPageResponse(
		Integer limit,
		Integer offset,
		Integer returnedCount
) {
}
