package com.portfolio.marketplace.productsearch.domain;

import com.portfolio.marketplace.product.domain.ProductColor;
import com.portfolio.marketplace.product.domain.ProductSize;
import com.portfolio.marketplace.product.domain.ProductStatus;
import com.portfolio.marketplace.product.domain.StockStatus;

public class ProductSearchCondition {

	private Long categoryId;
	private Long brandId;
	private ProductStatus status;
	private Integer minPrice;
	private Integer maxPrice;
	private ProductColor color;
	private ProductSize size;
	private StockStatus stockStatus;
	private String sort = "createdAtDesc";
	private Integer limit = 50;
	private Integer offset = 0;

	public ProductSearchCondition() {
	}

	public ProductSearchCondition(
			Long categoryId,
			Long brandId,
			ProductStatus status,
			Integer minPrice,
			Integer maxPrice,
			ProductColor color,
			ProductSize size,
			StockStatus stockStatus,
			String sort,
			Integer limit,
			Integer offset
	) {
		this.categoryId = categoryId;
		this.brandId = brandId;
		this.status = status;
		this.minPrice = minPrice;
		this.maxPrice = maxPrice;
		this.color = color;
		this.size = size;
		this.stockStatus = stockStatus;
		this.sort = sort;
		this.limit = limit;
		this.offset = offset;
	}

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
}
