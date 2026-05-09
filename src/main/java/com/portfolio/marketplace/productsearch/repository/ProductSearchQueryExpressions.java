package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.product.domain.QProduct;
import com.portfolio.marketplace.product.domain.QProductOption;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.querydsl.core.BooleanBuilder;
import com.querydsl.core.types.OrderSpecifier;
import com.querydsl.core.types.Predicate;
import com.querydsl.jpa.JPAExpressions;

final class ProductSearchQueryExpressions {

	private ProductSearchQueryExpressions() {
	}

	static Predicate where(ProductSearchCondition condition, QProduct product) {
		BooleanBuilder builder = new BooleanBuilder();
		if (condition.getCategoryId() != null) {
			builder.and(product.categoryId.eq(condition.getCategoryId()));
		}
		if (condition.getBrandId() != null) {
			builder.and(product.brandId.eq(condition.getBrandId()));
		}
		if (condition.getStatus() != null) {
			builder.and(product.status.eq(condition.getStatus()));
		}
		if (condition.getMinPrice() != null) {
			builder.and(product.price.goe(condition.getMinPrice()));
		}
		if (condition.getMaxPrice() != null) {
			builder.and(product.price.loe(condition.getMaxPrice()));
		}
		if (hasOptionFilter(condition)) {
			builder.and(optionExists(condition, product));
		}
		return builder;
	}

	static OrderSpecifier<?>[] orderBy(String sort, QProduct product) {
		return switch (sort) {
			case "reviewCountDesc" -> new OrderSpecifier<?>[] {
					product.reviewCount.desc(),
					product.id.desc()
			};
			case "priceAsc" -> new OrderSpecifier<?>[] {
					product.price.asc(),
					product.id.asc()
			};
			case "priceDesc" -> new OrderSpecifier<?>[] {
					product.price.desc(),
					product.id.desc()
			};
			case "createdAtDesc" -> new OrderSpecifier<?>[] {
					product.createdAt.desc(),
					product.id.desc()
			};
			default -> throw new IllegalArgumentException("Unsupported sort: " + sort);
		};
	}

	private static boolean hasOptionFilter(ProductSearchCondition condition) {
		return condition.getColor() != null
				|| condition.getSize() != null
				|| condition.getStockStatus() != null;
	}

	private static Predicate optionExists(ProductSearchCondition condition, QProduct product) {
		QProductOption option = QProductOption.productOption;
		BooleanBuilder builder = new BooleanBuilder()
				.and(option.product.id.eq(product.id));

		if (condition.getColor() != null) {
			builder.and(option.color.eq(condition.getColor()));
		}
		if (condition.getSize() != null) {
			builder.and(option.size.eq(condition.getSize()));
		}
		if (condition.getStockStatus() != null) {
			builder.and(option.stockStatus.eq(condition.getStockStatus()));
		}

		return JPAExpressions
				.selectOne()
				.from(option)
				.where(builder)
				.exists();
	}
}
