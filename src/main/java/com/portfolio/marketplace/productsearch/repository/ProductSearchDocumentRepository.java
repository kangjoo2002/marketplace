package com.portfolio.marketplace.productsearch.repository;

import com.portfolio.marketplace.productsearch.config.ProductSearchBaselineProperties;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocument;
import com.portfolio.marketplace.productsearch.domain.ProductSearchDocumentOption;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.regex.Pattern;
import org.springframework.dao.EmptyResultDataAccessException;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class ProductSearchDocumentRepository {

	private static final Pattern SAFE_IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");

	private final NamedParameterJdbcTemplate jdbcTemplate;
	private final String productsTable;
	private final String productOptionsTable;

	public ProductSearchDocumentRepository(
			NamedParameterJdbcTemplate jdbcTemplate,
			ProductSearchBaselineProperties properties
	) {
		this.jdbcTemplate = jdbcTemplate;
		this.productsTable = requireSafeIdentifier(properties.getProductsTable(), "productsTable");
		this.productOptionsTable = requireSafeIdentifier(properties.getProductOptionsTable(), "productOptionsTable");
	}

	public Optional<ProductSearchDocument> findByProductId(long productId) {
		Map<String, Object> params = Map.of("productId", productId);
		String sql = """
				SELECT
				    p.id AS product_id,
				    p.seller_id,
				    p.category_id,
				    p.brand_id,
				    p.status,
				    p.price,
				    p.rating,
				    p.review_count,
				    p.created_at,
				    p.updated_at
				FROM %s p
				WHERE p.id = :productId
				""".formatted(productsTable);

		try {
			ProductSearchDocument document = jdbcTemplate.queryForObject(sql, params, documentRowMapper());
			if (document == null) {
				return Optional.empty();
			}
			return Optional.of(document.withOptions(findOptionsByProductId(productId)));
		} catch (EmptyResultDataAccessException exception) {
			return Optional.empty();
		}
	}

	private List<ProductSearchDocumentOption> findOptionsByProductId(long productId) {
		String sql = """
				SELECT color, size, stock_status
				FROM %s
				WHERE product_id = :productId
				ORDER BY id
				""".formatted(productOptionsTable);
		return jdbcTemplate.query(
				sql,
				Map.of("productId", productId),
				(rs, rowNum) -> new ProductSearchDocumentOption(
						rs.getString("color"),
						rs.getString("size"),
						rs.getString("stock_status")
				)
		);
	}

	private static RowMapper<ProductSearchDocument> documentRowMapper() {
		return (rs, rowNum) -> new ProductSearchDocument(
				rs.getLong("product_id"),
				rs.getLong("seller_id"),
				rs.getLong("category_id"),
				rs.getLong("brand_id"),
				rs.getString("status"),
				rs.getInt("price"),
				rs.getBigDecimal("rating"),
				rs.getInt("review_count"),
				toLocalDateTime(rs, "created_at"),
				toLocalDateTime(rs, "updated_at"),
				toLocalDateTime(rs, "updated_at"),
				null,
				List.of()
		);
	}

	private static String requireSafeIdentifier(String value, String propertyName) {
		if (value == null || !SAFE_IDENTIFIER.matcher(value).matches()) {
			throw new IllegalArgumentException(propertyName + " must be a simple database identifier");
		}
		return value;
	}

	private static java.time.LocalDateTime toLocalDateTime(ResultSet rs, String column) throws SQLException {
		Timestamp timestamp = rs.getTimestamp(column);
		return timestamp == null ? null : timestamp.toLocalDateTime();
	}
}
