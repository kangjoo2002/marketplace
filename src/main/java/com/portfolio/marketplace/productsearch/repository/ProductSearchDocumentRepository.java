package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.product.domain.Product;
import com.portfolio.marketplace.product.domain.QProduct;
import com.portfolio.marketplace.product.domain.QProductOption;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocumentOption;
import com.querydsl.core.types.Projections;
import com.querydsl.jpa.impl.JPAQueryFactory;
import java.util.List;
import java.util.Optional;
import org.springframework.stereotype.Repository;

@Repository
public class ProductSearchDocumentRepository {

	private final JPAQueryFactory queryFactory;

	public ProductSearchDocumentRepository(JPAQueryFactory queryFactory) {
		this.queryFactory = queryFactory;
	}

	public Optional<ProductSearchDocument> findByProductId(long productId) {
		QProduct product = QProduct.product;
		Product foundProduct = queryFactory
				.selectFrom(product)
				.where(product.id.eq(productId))
				.fetchOne();

		if (foundProduct == null) {
			return Optional.empty();
		}
		return Optional.of(toDocument(foundProduct, findOptionsByProductId(productId)));
	}

	private List<ProductSearchDocumentOption> findOptionsByProductId(long productId) {
		QProductOption option = QProductOption.productOption;
		return queryFactory
				.select(Projections.constructor(
						ProductSearchDocumentOption.class,
						option.color.stringValue(),
						option.size.stringValue(),
						option.stockStatus.stringValue()
				))
				.from(option)
				.where(option.product.id.eq(productId))
				.orderBy(option.id.asc())
				.fetch();
	}

	private static ProductSearchDocument toDocument(
			Product product,
			List<ProductSearchDocumentOption> options
	) {
		return new ProductSearchDocument(
				product.getId(),
				product.getSellerId(),
				product.getCategoryId(),
				product.getBrandId(),
				product.getStatus().name(),
				product.getPrice(),
				product.getRating(),
				product.getReviewCount(),
				product.getCreatedAt(),
				product.getUpdatedAt(),
				product.getUpdatedAt(),
				null,
				options
		);
	}
}
