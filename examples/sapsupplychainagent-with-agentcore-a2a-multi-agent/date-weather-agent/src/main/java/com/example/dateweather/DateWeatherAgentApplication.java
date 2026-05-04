package com.example.dateweather;

import com.example.a2a.controller.A2AServerController;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.context.annotation.Import;

@SpringBootApplication
@Import(A2AServerController.class)
public class DateWeatherAgentApplication {

    public static void main(String[] args) {
        SpringApplication.run(DateWeatherAgentApplication.class, args);
    }
}
