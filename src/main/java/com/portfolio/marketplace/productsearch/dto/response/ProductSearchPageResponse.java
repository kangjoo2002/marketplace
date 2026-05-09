package com.portfolio.marketplace.productsearch.dto.response;

public record ProductSearchPageResponse(
		Integer limit,
		Integer offset,
		Integer returnedCount
) {
}



