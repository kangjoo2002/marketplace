package com.portfolio.readpath_lab.product.repository;

import com.portfolio.readpath_lab.product.api.ProductSearchItemResponse;
import com.portfolio.readpath_lab.product.api.ProductSearchRequest;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Pattern;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.jdbc.core.namedparam.NamedParameterJdbcTemplate;
import org.springframework.stereotype.Repository;

@Repository
public class ProductSearchRepository {

	private static final Pattern SAFE_IDENTIFIER = Pattern.compile("[A-Za-z_][A-Za-z0-9_]*");
	private static final String PRODUCT_SEARCH_DOCUMENTS_TABLE = "product_search_documents_moderate_skew";

	private final NamedParameterJdbcTemplate jdbcTemplate;
	private final String productsTable;
	private final String productOptionsTable;

	public ProductSearchRepository(
			NamedParameterJdbcTemplate jdbcTemplate,
			ProductSearchBaselineProperties properties
	) {
		this.jdbcTemplate = jdbcTemplate;
		this.productsTable = requireSafeIdentifier(properties.getProductsTable(), "productsTable");
		this.productOptionsTable = requireSafeIdentifier(properties.getProductOptionsTable(), "productOptionsTable");
	}

	public List<ProductSearchItemResponse> search(ProductSearchRequest request) {
		Map<String, Object> params = new HashMap<>();
		StringBuilder sql = new StringBuilder()
				.append("SELECT DISTINCT ")
				.append("p.id, p.seller_id, p.category_id, p.brand_id, p.status, ")
				.append("p.price, p.rating, p.review_count, p.created_at, p.updated_at ")
				.append("FROM ").append(productsTable).append(" p ")
				.append("JOIN ").append(productOptionsTable).append(" po ON po.product_id = p.id ")
				.append("WHERE 1 = 1 ");

		appendFilter(sql, params, "p.category_id", "categoryId", request.getCategoryId());
		appendFilter(sql, params, "p.brand_id", "brandId", request.getBrandId());
		appendFilter(sql, params, "p.status", "status", request.getStatus() == null ? null : request.getStatus().name());
		appendFilter(sql, params, "po.color", "color", request.getColor() == null ? null : request.getColor().name());
		appendFilter(sql, params, "po.size", "size", request.getSize() == null ? null : request.getSize().name());
		appendFilter(
				sql,
				params,
				"po.stock_status",
				"stockStatus",
				request.getStockStatus() == null ? null : request.getStockStatus().name()
		);

		if (request.getMinPrice() != null) {
			sql.append("AND p.price >= :minPrice ");
			params.put("minPrice", request.getMinPrice());
		}
		if (request.getMaxPrice() != null) {
			sql.append("AND p.price <= :maxPrice ");
			params.put("maxPrice", request.getMaxPrice());
		}

		sql.append(orderBy(request.getSort()));
		sql.append(" LIMIT :limit OFFSET :offset");
		params.put("limit", request.getLimit());
		params.put("offset", request.getOffset());

		return jdbcTemplate.query(sql.toString(), params, rowMapper());
	}

	public List<ProductSearchItemResponse> searchDenormalizedDb(ProductSearchRequest request) {
		Map<String, Object> params = new HashMap<>();
		StringBuilder sql = new StringBuilder()
				.append("SELECT ")
				.append("psd.product_id AS id, psd.seller_id, psd.category_id, psd.brand_id, psd.status, ")
				.append("psd.price, psd.rating, psd.review_count, psd.created_at, psd.updated_at ")
				.append("FROM ").append(PRODUCT_SEARCH_DOCUMENTS_TABLE).append(" psd ")
				.append("WHERE 1 = 1 ");

		appendFilter(sql, params, "psd.category_id", "categoryId", request.getCategoryId());
		appendFilter(sql, params, "psd.brand_id", "brandId", request.getBrandId());
		appendFilter(sql, params, "psd.status", "status", request.getStatus() == null ? null : request.getStatus().name());

		if (request.getMinPrice() != null) {
			sql.append("AND psd.price >= :minPrice ");
			params.put("minPrice", request.getMinPrice());
		}
		if (request.getMaxPrice() != null) {
			sql.append("AND psd.price <= :maxPrice ");
			params.put("maxPrice", request.getMaxPrice());
		}

		appendOptionSignatureFilter(sql, params, request);

		sql.append(denormalizedOrderBy(request.getSort()));
		sql.append(" LIMIT :limit OFFSET :offset");
		params.put("limit", request.getLimit());
		params.put("offset", request.getOffset());

		return jdbcTemplate.query(sql.toString(), params, rowMapper());
	}

	public List<ProductSearchItemResponse> searchDbTuned(ProductSearchRequest request) {
		Map<String, Object> params = new HashMap<>();
		StringBuilder sql = new StringBuilder()
				.append("SELECT ")
				.append("p.id, p.seller_id, p.category_id, p.brand_id, p.status, ")
				.append("p.price, p.rating, p.review_count, p.created_at, p.updated_at ")
				.append("FROM ").append(productsTable).append(" p ")
				.append("WHERE 1 = 1 ");

		appendFilter(sql, params, "p.category_id", "categoryId", request.getCategoryId());
		appendFilter(sql, params, "p.brand_id", "brandId", request.getBrandId());
		appendFilter(sql, params, "p.status", "status", request.getStatus() == null ? null : request.getStatus().name());

		if (request.getMinPrice() != null) {
			sql.append("AND p.price >= :minPrice ");
			params.put("minPrice", request.getMinPrice());
		}
		if (request.getMaxPrice() != null) {
			sql.append("AND p.price <= :maxPrice ");
			params.put("maxPrice", request.getMaxPrice());
		}

		appendOptionExistsFilter(sql, params, request);

		sql.append(orderBy(request.getSort()));
		sql.append(" LIMIT :limit OFFSET :offset");
		params.put("limit", request.getLimit());
		params.put("offset", request.getOffset());

		return jdbcTemplate.query(sql.toString(), params, rowMapper());
	}

	private static void appendFilter(
			StringBuilder sql,
			Map<String, Object> params,
			String column,
			String parameter,
			Object value
	) {
		if (value == null) {
			return;
		}
		sql.append("AND ").append(column).append(" = :").append(parameter).append(" ");
		params.put(parameter, value);
	}

	private void appendOptionExistsFilter(StringBuilder sql, Map<String, Object> params, ProductSearchRequest request) {
		sql.append("AND EXISTS (")
				.append("SELECT 1 FROM ").append(productOptionsTable).append(" po ")
				.append("WHERE po.product_id = p.id ");

		appendFilter(sql, params, "po.color", "color", request.getColor() == null ? null : request.getColor().name());
		appendFilter(sql, params, "po.size", "size", request.getSize() == null ? null : request.getSize().name());
		appendFilter(
				sql,
				params,
				"po.stock_status",
				"stockStatus",
				request.getStockStatus() == null ? null : request.getStockStatus().name()
		);

		sql.append(") ");
	}

	private static void appendOptionSignatureFilter(
			StringBuilder sql,
			Map<String, Object> params,
			ProductSearchRequest request
	) {
		String color = request.getColor() == null ? null : request.getColor().name();
		String size = request.getSize() == null ? null : request.getSize().name();
		String stockStatus = request.getStockStatus() == null ? null : request.getStockStatus().name();
		int optionFilterCount = (color == null ? 0 : 1) + (size == null ? 0 : 1) + (stockStatus == null ? 0 : 1);

		if (optionFilterCount == 0) {
			return;
		}

		if (optionFilterCount == 3) {
			sql.append("AND psd.option_signatures @> ARRAY[")
					.append("make_product_option_signature(:color, :size, :stockStatus)")
					.append("] ");
			params.put("color", color);
			params.put("size", size);
			params.put("stockStatus", stockStatus);
			return;
		}

		sql.append("AND EXISTS (")
				.append("SELECT 1 FROM unnest(psd.option_signatures) AS option_signature ")
				.append("WHERE 1 = 1 ");

		if (color != null) {
			sql.append("AND split_part(option_signature, '|', 1) = :color ");
			params.put("color", color);
		}
		if (size != null) {
			sql.append("AND split_part(option_signature, '|', 2) = :size ");
			params.put("size", size);
		}
		if (stockStatus != null) {
			sql.append("AND split_part(option_signature, '|', 3) = :stockStatus ");
			params.put("stockStatus", stockStatus);
		}

		sql.append(") ");
	}

	private static String orderBy(String sort) {
		return switch (sort) {
			case "reviewCountDesc" -> "ORDER BY p.review_count DESC, p.id DESC";
			case "priceAsc" -> "ORDER BY p.price ASC, p.id ASC";
			case "priceDesc" -> "ORDER BY p.price DESC, p.id DESC";
			case "createdAtDesc" -> "ORDER BY p.created_at DESC, p.id DESC";
			default -> throw new IllegalArgumentException("Unsupported sort: " + sort);
		};
	}

	private static String denormalizedOrderBy(String sort) {
		return switch (sort) {
			case "reviewCountDesc" -> "ORDER BY psd.review_count DESC, psd.product_id DESC";
			case "priceAsc" -> "ORDER BY psd.price ASC, psd.product_id ASC";
			case "priceDesc" -> "ORDER BY psd.price DESC, psd.product_id DESC";
			case "createdAtDesc" -> "ORDER BY psd.created_at DESC, psd.product_id DESC";
			default -> throw new IllegalArgumentException("Unsupported sort: " + sort);
		};
	}

	private static String requireSafeIdentifier(String value, String propertyName) {
		if (value == null || !SAFE_IDENTIFIER.matcher(value).matches()) {
			throw new IllegalArgumentException(propertyName + " must be a simple database identifier");
		}
		return value;
	}

	private static RowMapper<ProductSearchItemResponse> rowMapper() {
		return (rs, rowNum) -> new ProductSearchItemResponse(
				rs.getLong("id"),
				rs.getLong("seller_id"),
				rs.getLong("category_id"),
				rs.getLong("brand_id"),
				rs.getString("status"),
				rs.getInt("price"),
				rs.getBigDecimal("rating"),
				rs.getInt("review_count"),
				toLocalDateTime(rs, "created_at"),
				toLocalDateTime(rs, "updated_at")
		);
	}

	private static java.time.LocalDateTime toLocalDateTime(ResultSet rs, String column) throws SQLException {
		Timestamp timestamp = rs.getTimestamp(column);
		return timestamp == null ? null : timestamp.toLocalDateTime();
	}
}
