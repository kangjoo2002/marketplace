package com.portfolio.marketplace.productsearch.domain;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public record ProductSearchItem(
		Long id,
		Long sellerId,
		Long categoryId,
		Long brandId,
		String status,
		Integer price,
		BigDecimal rating,
		Integer reviewCount,
		LocalDateTime createdAt,
		LocalDateTime updatedAt
) {
}
