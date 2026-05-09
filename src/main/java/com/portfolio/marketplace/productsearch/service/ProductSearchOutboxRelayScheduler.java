package com.portfolio.marketplace.productsearch.service;

import com.portfolio.marketplace.productsearch.config.ProductSearchIndexingProperties;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

@Component
public class ProductSearchOutboxRelayScheduler {

	private final ProductSearchOutboxRelayService relayService;
	private final ProductSearchIndexingProperties indexingProperties;

	public ProductSearchOutboxRelayScheduler(
			ProductSearchOutboxRelayService relayService,
			ProductSearchIndexingProperties indexingProperties
	) {
		this.relayService = relayService;
		this.indexingProperties = indexingProperties;
	}

	@Scheduled(fixedDelayString = "${readpath.product-search.indexing.relay.fixed-delay-ms:5000}")
	public void relayPendingEvents() {
		if (!indexingProperties.getRelay().isEnabled()) {
			return;
		}
		relayService.processBatch();
	}
}
