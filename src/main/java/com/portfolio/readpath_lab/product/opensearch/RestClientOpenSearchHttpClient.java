package com.portfolio.readpath_lab.product.opensearch;

import com.portfolio.readpath_lab.product.application.ProductSearchFallbackMetrics.OpenSearchFailureReason;
import com.portfolio.readpath_lab.product.application.ProductSearchReadPathProperties;
import java.net.SocketTimeoutException;
import java.util.Map;
import org.springframework.http.client.SimpleClientHttpRequestFactory;
import org.springframework.stereotype.Component;
import org.springframework.web.client.ResourceAccessException;
import org.springframework.web.client.RestClient;
import org.springframework.web.client.RestClientResponseException;

@Component
public class RestClientOpenSearchHttpClient implements OpenSearchHttpClient {

	private final RestClient restClient;
	private final String searchPath;

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
