package com.portfolio.readpath_lab;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.context.properties.ConfigurationPropertiesScan;

@SpringBootApplication
@ConfigurationPropertiesScan
public class ReadpathLabApplication {

	public static void main(String[] args) {
		SpringApplication.run(ReadpathLabApplication.class, args);
	}

}
