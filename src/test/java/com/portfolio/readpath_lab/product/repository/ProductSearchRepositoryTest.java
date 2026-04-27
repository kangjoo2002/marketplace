package com.portfolio.readpath_lab.product.repository;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import com.portfolio.readpath_lab.product.domain.ProductColor;
import com.portfolio.readpath_lab.product.domain.ProductSize;
import com.portfolio.readpath_lab.product.domain.ProductStatus;
import com.portfolio.readpath_lab.product.domain.StockStatus;
import java.util.List;
import java.util.Map;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.when;

class ProductSearchRepositoryTest {

	@Test
	void searchUsesJoinDistinctOffsetBaselineShape() {
		NamedParameterJdbcTemplate jdbcTemplate = mock(NamedParameterJdbcTemplate.class);
		ArgumentCaptor<String> sqlCaptor = ArgumentCaptor.forClass(String.class);
		when(jdbcTemplate.query(
				sqlCaptor.capture(),
				anyMap(),
				ArgumentMatchers.<RowMapper<ProductSearchItemResponse>>any()
		)).thenReturn(List.<ProductSearchItemResponse>of());

		ProductSearchBaselineProperties properties = new ProductSearchBaselineProperties();
		ProductSearchRepository repository = new ProductSearchRepository(jdbcTemplate, properties);

		ProductSearchRequest request = new ProductSearchRequest();
		request.setCategoryId(35L);
		request.setBrandId(543L);
		request.setStatus(ProductStatus.ACTIVE);
		request.setMinPrice(10000);
		request.setMaxPrice(100000);
		request.setColor(ProductColor.WHITE);
		request.setSize(ProductSize.L);
		request.setStockStatus(StockStatus.OUT_OF_STOCK);
		request.setSort("reviewCountDesc");
		request.setLimit(50);
		request.setOffset(100);

		repository.search(request);

		String sql = sqlCaptor.getValue();
		assertThat(sql).contains("SELECT DISTINCT");
		assertThat(sql).contains("FROM products_moderate_skew p");
		assertThat(sql).contains("JOIN product_options_moderate_skew po ON po.product_id = p.id");
		assertThat(sql).contains("ORDER BY p.review_count DESC, p.id DESC");
		assertThat(sql).contains("LIMIT :limit OFFSET :offset");
		assertThat(sql).doesNotContainIgnoringCase("exists");
	}
}
