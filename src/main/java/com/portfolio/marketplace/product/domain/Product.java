package com.portfolio.marketplace.product.domain;

import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;
import java.math.BigDecimal;
import java.time.LocalDateTime;

@Entity
@Table(name = "products")
public class Product {

	@Id
	@GeneratedValue(strategy = GenerationType.IDENTITY)
	private Long id;

	@Column(name = "seller_id", nullable = false)
	private Long sellerId;

	@Column(name = "category_id", nullable = false)
	private Long categoryId;

	@Column(name = "brand_id", nullable = false)
	private Long brandId;

	@Enumerated(EnumType.STRING)
	@Column(nullable = false)
	private ProductStatus status;

	@Column(nullable = false)
	private Integer price;

	@Column(nullable = false, precision = 3, scale = 2)
	private BigDecimal rating;

	@Column(name = "review_count", nullable = false)
	private Integer reviewCount;

	@Column(name = "created_at", nullable = false)
	private LocalDateTime createdAt;

	@Column(name = "updated_at", nullable = false)
	private LocalDateTime updatedAt;

	protected Product() {
	}

	public Long getId() {
		return id;
	}

	public Long getSellerId() {
		return sellerId;
	}

	public Long getCategoryId() {
		return categoryId;
	}

	public Long getBrandId() {
		return brandId;
	}

	public ProductStatus getStatus() {
		return status;
	}

	public Integer getPrice() {
		return price;
	}

	public BigDecimal getRating() {
		return rating;
	}

	public Integer getReviewCount() {
		return reviewCount;
	}

	public LocalDateTime getCreatedAt() {
		return createdAt;
	}

	public LocalDateTime getUpdatedAt() {
		return updatedAt;
	}
}
