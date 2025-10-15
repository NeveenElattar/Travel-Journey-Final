//
//  LiveJournalService.swift
//  TripJournal
//
//  Created by Neveen ElAttar on 13/10/2025.
//


import Combine
import Foundation

/// API Error that contains detailed error information from the server
struct APIError: LocalizedError, Decodable {
    let detail: String
    
    var errorDescription: String? {
        return detail
    }
}

/// A live implementation of the `JournalService` that communicates with the API.
class LiveJournalService: JournalService {
    
    // MARK: - Properties
    
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    
    @Published private var token: Token?
    
    var isAuthenticated: AnyPublisher<Bool, Never> {
        $token
            .map { $0 != nil }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Initialization
    
    init(baseURL: URL = URL(string: "http://localhost:8000")!) {
        self.baseURL = baseURL
        self.session = URLSession.shared
        
        // Configure decoder for ISO8601 dates
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        
        // Configure encoder for ISO8601 dates
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        
        // Try to load saved token from UserDefaults
        self.token = Self.loadToken()
    }
    
    // MARK: - Token Storage
    
    private static let tokenKey = "com.tripjournal.authToken"
    
    private static func loadToken() -> Token? {
        guard let data = UserDefaults.standard.data(forKey: tokenKey) else {
            return nil
        }
        return try? JSONDecoder().decode(Token.self, from: data)
    }
    
    private func saveToken(_ token: Token) {
        if let data = try? JSONEncoder().encode(token) {
            UserDefaults.standard.set(data, forKey: Self.tokenKey)
        }
        self.token = token
    }
    
    private func clearToken() {
        UserDefaults.standard.removeObject(forKey: Self.tokenKey)
        self.token = nil
    }
    
    // MARK: - Helper Methods
    
    private func makeRequest(
        _ endpoint: String,
        method: String = "GET",
        body: Data? = nil,
        requiresAuth: Bool = true
    ) throws -> URLRequest {
        let url = baseURL.appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        
        // Add authorization header if token exists and auth is required
        if requiresAuth, let token = token {
            request.setValue("Bearer \(token.accessToken)", forHTTPHeaderField: "Authorization")
        }
        
        // Add content type for POST/PUT requests
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        return request
    }
    
    private func handleResponse(data: Data, response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        // If response is successful, return
        if (200...299).contains(httpResponse.statusCode) {
            return
        }
        
        // Try to decode API error message
        if let apiError = try? decoder.decode(APIError.self, from: data) {
            throw apiError
        }
        
        // Fallback to generic HTTP errors
        switch httpResponse.statusCode {
        case 400:
            throw APIError(detail: "Bad request. Please check your input.")
        case 401:
            throw APIError(detail: "Invalid credentials. Please check your username and password.")
        case 404:
            throw APIError(detail: "Resource not found.")
        case 422:
            throw APIError(detail: "Invalid data format. Please check your input.")
        case 500...599:
            throw APIError(detail: "Server error. Please try again later.")
        default:
            throw APIError(detail: "An unexpected error occurred. Please try again.")
        }
    }
    
    // MARK: - Authentication
    
    func register(username: String, password: String) async throws -> Token {
        // Create request body
        let body = ["username": username, "password": password]
        let bodyData = try encoder.encode(body)
        
        // Make request
        var request = try makeRequest("register", method: "POST", body: bodyData, requiresAuth: false)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        // Send request
        let (data, response) = try await session.data(for: request)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
        
        // Decode token
        let token = try decoder.decode(Token.self, from: data)
        
        // Save token
        saveToken(token)
        
        return token
    }
    
    func logIn(username: String, password: String) async throws -> Token {
        // Login uses OAuth2 form data, not JSON
        // Create properly encoded form data
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "password"),
            URLQueryItem(name: "username", value: username),
            URLQueryItem(name: "password", value: password)
        ]
        
        // Get the query string (without the leading '?')
        guard let queryString = components.percentEncodedQuery,
              let bodyData = queryString.data(using: .utf8) else {
            throw URLError(.badURL)
        }
        
        // Make request
        var request = try makeRequest("token", method: "POST", body: bodyData, requiresAuth: false)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        // Send request
        let (data, response) = try await session.data(for: request)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
        
        // Decode token
        let token = try decoder.decode(Token.self, from: data)
        
        // Save token
        saveToken(token)
        
        return token
    }
    
    func logOut() {
        Task { @MainActor in
            clearToken()
        }
    }
    
    // MARK: - Trips
    
    func createTrip(with request: TripCreate) async throws -> Trip {
        // Encode request body
        let bodyData = try encoder.encode(request)
        
        // Make request
        let urlRequest = try makeRequest("trips", method: "POST", body: bodyData)
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Decode and return trip
        return try decoder.decode(Trip.self, from: data)
    }
    
    func getTrips() async throws -> [Trip] {
        // Make request
        let urlRequest = try makeRequest("trips", method: "GET")
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Decode and return trips
        return try decoder.decode([Trip].self, from: data)
    }
    
    func getTrip(withId tripId: Trip.ID) async throws -> Trip {
        // Make request
        let urlRequest = try makeRequest("trips/\(tripId)", method: "GET")
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Decode and return trip
        return try decoder.decode(Trip.self, from: data)
    }
    
    func updateTrip(withId tripId: Trip.ID, and request: TripUpdate) async throws -> Trip {
        // Encode request body
        let bodyData = try encoder.encode(request)
        
        // Make request
        let urlRequest = try makeRequest("trips/\(tripId)", method: "PUT", body: bodyData)
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
        
        // Decode and return updated trip
        return try decoder.decode(Trip.self, from: data)
    }
    
    func deleteTrip(withId tripId: Trip.ID) async throws {
        // Make request
        let urlRequest = try makeRequest("trips/\(tripId)", method: "DELETE")
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    
    // MARK: - Events
    
    func createEvent(with request: EventCreate) async throws -> Event {
        // Encode request body
        let bodyData = try encoder.encode(request)
        
        // Make request
        let urlRequest = try makeRequest("events", method: "POST", body: bodyData)
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
        
        // Decode and return event
        return try decoder.decode(Event.self, from: data)
    }
    
    func updateEvent(withId eventId: Event.ID, and request: EventUpdate) async throws -> Event {
        // Encode request body
        let bodyData = try encoder.encode(request)
        
        // Make request
        let urlRequest = try makeRequest("events/\(eventId)", method: "PUT", body: bodyData)
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
        
        // Decode and return updated event
        return try decoder.decode(Event.self, from: data)
    }
    
    func deleteEvent(withId eventId: Event.ID) async throws {
        // Make request
        let urlRequest = try makeRequest("events/\(eventId)", method: "DELETE")
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
    }
    
    // MARK: - Media
    
    func createMedia(with request: MediaCreate) async throws -> Media {
        // Encode request body
        let bodyData = try encoder.encode(request)
        
        // Make request
        let urlRequest = try makeRequest("media", method: "POST", body: bodyData)
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
        
        // Decode and return media
        return try decoder.decode(Media.self, from: data)
    }
    
    func deleteMedia(withId mediaId: Media.ID) async throws {
        // Make request
        let urlRequest = try makeRequest("media/\(mediaId)", method: "DELETE")
        
        // Send request
        let (data, response) = try await session.data(for: urlRequest)
        
        // Check response and handle errors
        try handleResponse(data: data, response: response)
    }
}

