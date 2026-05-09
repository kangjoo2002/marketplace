package com.portfolio.marketplace.productsearch.dto.response;

import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import java.util.List;

public record ProductSearchResponse(
		List<ProductSearchItemResponse> items,
		ProductSearchPageResponse page
) {

	public static ProductSearchResponse of(
			List<ProductSearchItemResponse> items,
			Integer limit,
			Integer offset
	) {
		return new ProductSearchResponse(
				items,
				new ProductSearchPageResponse(limit, offset, items.size())
		);
	}

	public static ProductSearchResponse from(
			List<ProductSearchItem> items,
			Integer limit,
			Integer offset
	) {
		return of(
				items.stream()
						.map(ProductSearchItemResponse::from)
						.toList(),
				limit,
				offset
		);
	}
}
