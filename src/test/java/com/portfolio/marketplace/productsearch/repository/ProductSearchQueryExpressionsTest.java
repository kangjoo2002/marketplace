package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.product.domain.ProductColor;
import com.portfolio.marketplace.product.domain.ProductSize;
import com.portfolio.marketplace.product.domain.ProductStatus;
import com.portfolio.marketplace.product.domain.QProduct;
import com.portfolio.marketplace.product.domain.StockStatus;
import com.portfolio.marketplace.productsearch.domain.ProductSearchCondition;
import com.querydsl.core.types.OrderSpecifier;
import com.querydsl.core.types.Predicate;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class ProductSearchQueryExpressionsTest {

	private final QProduct product = QProduct.product;

	@Test
	void whereBuildsProductFiltersAndOptionExistsPredicate() {
		ProductSearchCondition condition = new ProductSearchCondition();
		condition.setCategoryId(75L);
		condition.setBrandId(943L);
		condition.setStatus(ProductStatus.ACTIVE);
		condition.setMinPrice(10000);
		condition.setMaxPrice(100000);
		condition.setColor(ProductColor.BLACK);
		condition.setSize(ProductSize.M);
		condition.setStockStatus(StockStatus.IN_STOCK);

		Predicate predicate = ProductSearchQueryExpressions.where(condition, product);

		assertThat(predicate.toString()).contains("product.categoryId = 75");
		assertThat(predicate.toString()).contains("product.brandId = 943");
		assertThat(predicate.toString()).contains("product.status = ACTIVE");
		assertThat(predicate.toString()).contains("product.price >= 10000");
		assertThat(predicate.toString()).contains("product.price <= 100000");
		assertThat(predicate.toString()).contains("exists");
	}

	@Test
	void whereDoesNotAddOptionExistsWithoutOptionFilters() {
		ProductSearchCondition condition = new ProductSearchCondition();
		condition.setCategoryId(75L);

		Predicate predicate = ProductSearchQueryExpressions.where(condition, product);

		assertThat(predicate.toString()).contains("product.categoryId = 75");
		assertThat(predicate.toString()).doesNotContain("exists");
		assertThat(predicate.toString()).doesNotContain("productOption");
	}

	@Test
	void orderByMapsSupportedSorts() {
		OrderSpecifier<?>[] orderSpecifiers = ProductSearchQueryExpressions.orderBy("createdAtDesc", product);

		assertThat(orderSpecifiers).hasSize(2);
		assertThat(orderSpecifiers[0].toString()).contains("product.createdAt DESC");
		assertThat(orderSpecifiers[1].toString()).contains("product.id DESC");
	}

	@Test
	void orderByRejectsUnsupportedSort() {
		assertThatThrownBy(() -> ProductSearchQueryExpressions.orderBy("ratingDesc", product))
				.isInstanceOf(IllegalArgumentException.class)
				.hasMessageContaining("Unsupported sort");
	}
}
