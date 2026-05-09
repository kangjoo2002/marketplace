package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.product.domain.QProduct;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.portfolio.marketplace.productsearch.domain.ProductSearchItem;
import com.querydsl.core.types.Projections;
import com.querydsl.jpa.impl.JPAQueryFactory;
import java.util.List;
import org.springframework.stereotype.Repository;

@Repository
public class ProductSearchQueryRepository {

	private final JPAQueryFactory queryFactory;

	public ProductSearchQueryRepository(JPAQueryFactory queryFactory) {
		this.queryFactory = queryFactory;
	}

	public List<ProductSearchItem> search(ProductSearchCondition condition) {
		QProduct product = QProduct.product;

		return queryFactory
				.select(Projections.constructor(
						ProductSearchItem.class,
						product.id,
						product.sellerId,
						product.categoryId,
						product.brandId,
						product.status.stringValue(),
						product.price,
						product.rating,
						product.reviewCount,
						product.createdAt,
						product.updatedAt
				))
				.from(product)
				.where(ProductSearchQueryExpressions.where(condition, product))
				.orderBy(ProductSearchQueryExpressions.orderBy(condition.getSort(), product))
				.limit(condition.getLimit())
				.offset(condition.getOffset())
				.fetch();
	}
}
