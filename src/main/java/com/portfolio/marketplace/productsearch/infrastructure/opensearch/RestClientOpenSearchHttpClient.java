package com.portfolio.marketplace.productsearch.infrastructure.opensearch;

import com.portfolio.marketplace.productsearch.service.ProductSearchFallbackMetrics.OpenSearchFailureReason;
import com.portfolio.marketplace.productsearch.config.ProductSearchReadPathProperties;
import java.net.SocketTimeoutException;
import java.util.Map;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

@Component
public class RestClientOpenSearchHttpClient implements OpenSearchSearchClient, OpenSearchDocumentClient {

	private final RestClient restClient;
	private final String searchPath;
	private final String documentPath;

	public RestClientOpenSearchHttpClient(ProductSearchReadPathProperties properties) {
		ProductSearchReadPathProperties.OpenSearch openSearch = properties.getOpenSearch();
		SimpleClientHttpRequestFactory requestFactory = new SimpleClientHttpRequestFactory();
		requestFactory.setConnectTimeout(openSearch.getTimeoutMs());
		requestFactory.setReadTimeout(openSearch.getTimeoutMs());

		this.restClient = RestClient.builder()
				.baseUrl(openSearch.getBaseUrl())
				.requestFactory(requestFactory)
				.build();
		this.searchPath = "/" + trimSlashes(openSearch.getIndexAlias()) + "/_search";
		this.documentPath = "/" + trimSlashes(openSearch.getWriteAlias()) + "/_doc/{documentId}";
	}

	@Override
	@SuppressWarnings("unchecked")
	public Map<String, Object> search(Map<String, Object> query) {
		try {
			Object response = restClient.post()
					.uri(searchPath)
					.body(query)
					.retrieve()
					.body(Map.class);

			if (!(response instanceof Map<?, ?> responseMap)) {
				throw new OpenSearchProductSearchException(
						OpenSearchFailureReason.MALFORMED_RESPONSE,
						"OpenSearch response body was not a JSON object"
				);
			}
			return (Map<String, Object>) responseMap;
		} catch (RestClientResponseException exception) {
			if (exception.getStatusCode().is5xxServerError()) {
				throw new OpenSearchProductSearchException(
						OpenSearchFailureReason.HTTP_5XX,
						"OpenSearch returned HTTP " + exception.getStatusCode().value(),
						exception
				);
			}
			throw exception;
		} catch (ResourceAccessException exception) {
			OpenSearchFailureReason reason = containsTimeout(exception)
					? OpenSearchFailureReason.TIMEOUT
					: OpenSearchFailureReason.CONNECTION_FAILURE;
			throw new OpenSearchProductSearchException(reason, "OpenSearch request failed", exception);
		}
	}

	@Override
	public void indexDocument(String documentId, Map<String, Object> document) {
		try {
			restClient.put()
					.uri(documentPath, documentId)
					.body(document)
					.retrieve()
					.toBodilessEntity();
		} catch (RestClientResponseException exception) {
			throw toOpenSearchException(exception);
		} catch (ResourceAccessException exception) {
			throw toOpenSearchException(exception);
		}
	}

	@Override
	public void deleteDocument(String documentId) {
		try {
			restClient.delete()
					.uri(documentPath, documentId)
					.retrieve()
					.toBodilessEntity();
		} catch (RestClientResponseException exception) {
			if (exception.getStatusCode().value() == 404) {
				return;
			}
			throw toOpenSearchException(exception);
		} catch (ResourceAccessException exception) {
			throw toOpenSearchException(exception);
		}
	}

	private static OpenSearchProductSearchException toOpenSearchException(RestClientResponseException exception) {
		if (exception.getStatusCode().is5xxServerError()) {
			return new OpenSearchProductSearchException(
					OpenSearchFailureReason.HTTP_5XX,
					"OpenSearch returned HTTP " + exception.getStatusCode().value(),
					exception
			);
		}
		return new OpenSearchProductSearchException(
				OpenSearchFailureReason.MALFORMED_RESPONSE,
				"OpenSearch returned HTTP " + exception.getStatusCode().value(),
				exception
		);
	}

	private static OpenSearchProductSearchException toOpenSearchException(ResourceAccessException exception) {
		OpenSearchFailureReason reason = containsTimeout(exception)
				? OpenSearchFailureReason.TIMEOUT
				: OpenSearchFailureReason.CONNECTION_FAILURE;
		return new OpenSearchProductSearchException(reason, "OpenSearch request failed", exception);
	}

	private static boolean containsTimeout(Throwable throwable) {
		Throwable current = throwable;
		while (current != null) {
			if (current instanceof SocketTimeoutException) {
				return true;
			}
			String message = current.getMessage();
			if (message != null && message.toLowerCase().contains("timed out")) {
				return true;
			}
			current = current.getCause();
		}
		return false;
	}

	private static String trimSlashes(String value) {
		return value.replaceAll("^/+", "").replaceAll("/+$", "");
	}
}




