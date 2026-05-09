package com.portfolio.marketplace.productsearch.dto.response;

import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
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

	public static ProductSearchItemResponse from(ProductSearchItem item) {
		return new ProductSearchItemResponse(
				item.id(),
				item.sellerId(),
				item.categoryId(),
				item.brandId(),
				item.status(),
				item.price(),
				item.rating(),
				item.reviewCount(),
				item.createdAt(),
				item.updatedAt()
		);
	}
}
