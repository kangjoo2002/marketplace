package com.portfolio.readpath_lab.product.api;

import java.math.BigDecimal;
import java.time.LocalDateTime;

public record ProductSearchItemResponse(
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
