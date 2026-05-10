package com.portfolio.marketplace.product.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.FetchType;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;

@Entity
@Table(name = "product_options")
public class ProductOption {

	@Id
	@GeneratedValue(strategy = GenerationType.IDENTITY)
	private Long id;

	@ManyToOne(fetch = FetchType.LAZY)
	@JoinColumn(name = "product_id", nullable = false)
	private Product product;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false)
	private ProductColor color;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false)
	private ProductSize size;

	@Enumerated(EnumType.STRING)
	@Column(name = "stock_status", nullable = false)
	private StockStatus stockStatus;

	protected ProductOption() {
	}

	public Long getId() {
		return id;
	}

	public Product getProduct() {
		return product;
	}

	public ProductColor getColor() {
		return color;
	}

	public ProductSize getSize() {
		return size;
	}

	public StockStatus getStockStatus() {
		return stockStatus;
	}
}
