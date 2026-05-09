package com.portfolio.marketplace.productsearch.config;

import org.springframework.boot.context.properties.ConfigurationProperties;

@ConfigurationProperties(prefix = "readpath.product-search.baseline")
public class ProductSearchBaselineProperties {

	private String productsTable = "products_moderate_skew";
	private String productOptionsTable = "product_options_moderate_skew";

	public String getProductsTable() {
		return productsTable;
	}

	public void setProductsTable(String productsTable) {
		this.productsTable = productsTable;
	}

	public String getProductOptionsTable() {
		return productOptionsTable;
	}

	public void setProductOptionsTable(String productOptionsTable) {
		this.productOptionsTable = productOptionsTable;
	}
}



