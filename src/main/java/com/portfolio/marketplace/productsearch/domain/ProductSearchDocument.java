package com.portfolio.marketplace.productsearch.domain;

import java.math.BigDecimal;
import java.time.LocalDateTime;
import java.util.List;

public record ProductSearchDocument(
		long productId,
		long sellerId,
		long categoryId,
		long brandId,
		String status,
		int price,
		BigDecimal rating,
		int reviewCount,
		LocalDateTime createdAt,
		LocalDateTime updatedAt,
		LocalDateTime sourceUpdatedAt,
		LocalDateTime documentRefreshedAt,
		List<ProductSearchDocumentOption> options
) {

	public ProductSearchDocument refreshedAt(LocalDateTime refreshedAt) {
		return new ProductSearchDocument(
				productId,
				sellerId,
				categoryId,
				brandId,
				status,
				price,
				rating,
				reviewCount,
				createdAt,
				updatedAt,
				sourceUpdatedAt,
				refreshedAt,
				options
		);
	}

	public ProductSearchDocument withOptions(List<ProductSearchDocumentOption> changedOptions) {
		return new ProductSearchDocument(
				productId,
				sellerId,
				categoryId,
				brandId,
				status,
				price,
				rating,
				reviewCount,
				createdAt,
				updatedAt,
				sourceUpdatedAt,
				documentRefreshedAt,
				List.copyOf(changedOptions)
		);
	}

	public boolean isDeleted() {
		return "DELETED".equals(status);
	}
}
