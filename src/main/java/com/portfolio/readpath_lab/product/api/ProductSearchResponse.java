package com.portfolio.readpath_lab.product.api;

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
}
