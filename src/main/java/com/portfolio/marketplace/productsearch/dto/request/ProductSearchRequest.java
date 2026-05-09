package com.portfolio.marketplace.productsearch.dto.request;

import com.portfolio.marketplace.product.domain.ProductColor;
import com.portfolio.marketplace.product.domain.ProductSize;
import com.portfolio.marketplace.product.domain.ProductStatus;
import com.portfolio.marketplace.product.domain.StockStatus;
import jakarta.validation.constraints.AssertTrue;
import jakarta.validation.constraints.Max;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.Pattern;

public class ProductSearchRequest {

	private Long categoryId;
	private Long brandId;
	private ProductStatus status;

	@Min(0)
	private Integer minPrice;

	@Min(0)
	private Integer maxPrice;

	private ProductColor color;
	private ProductSize size;
	private StockStatus stockStatus;

	@Pattern(regexp = "reviewCountDesc|priceAsc|priceDesc|createdAtDesc")
	private String sort = "createdAtDesc";

	@Min(1)
	@Max(100)
	private Integer limit = 50;

	@Min(0)
	private Integer offset = 0;

	public Long getCategoryId() {
		return categoryId;
	}

	public void setCategoryId(Long categoryId) {
		this.categoryId = categoryId;
	}

	public Long getBrandId() {
		return brandId;
	}

	public void setBrandId(Long brandId) {
		this.brandId = brandId;
	}

	public ProductStatus getStatus() {
		return status;
	}

	public void setStatus(ProductStatus status) {
		this.status = status;
	}

	public Integer getMinPrice() {
		return minPrice;
	}

	public void setMinPrice(Integer minPrice) {
		this.minPrice = minPrice;
	}

	public Integer getMaxPrice() {
		return maxPrice;
	}

	public void setMaxPrice(Integer maxPrice) {
		this.maxPrice = maxPrice;
	}

	public ProductColor getColor() {
		return color;
	}

	public void setColor(ProductColor color) {
		this.color = color;
	}

	public ProductSize getSize() {
		return size;
	}

	public void setSize(ProductSize size) {
		this.size = size;
	}

	public StockStatus getStockStatus() {
		return stockStatus;
	}

	public void setStockStatus(StockStatus stockStatus) {
		this.stockStatus = stockStatus;
	}

	public String getSort() {
		return sort;
	}

	public void setSort(String sort) {
		this.sort = sort;
	}

	public Integer getLimit() {
		return limit;
	}

	public void setLimit(Integer limit) {
		this.limit = limit;
	}

	public Integer getOffset() {
		return offset;
	}

	public void setOffset(Integer offset) {
		this.offset = offset;
	}

	@AssertTrue(message = "minPrice must be less than or equal to maxPrice")
	public boolean isValidPriceRange() {
		return minPrice == null || maxPrice == null || minPrice <= maxPrice;
	}
}



