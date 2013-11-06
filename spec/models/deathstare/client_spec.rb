require 'spec_helper'

module Deathstare
  describe Client do
    it 'processes a successful JSON response' do
      promise = Client.new('http://test.host').http :get, '/foods/burrito'
      promise.then { |response| @response = response }

      promise.handle_response double('Typhoeus::Response', success?: true,
                                     body: Yajl::Encoder.encode({foo: 'bar'}),
                                     response_code: 200, status_message: 'OK', total_time: 1,
                                     request: double('Typhoeus::Request', options: {method: 'get'}, url: ''))

      expect(@response).to eq(
                             _response_meta: {request_method: "GET", request_url: "", status_code: 200, status_message: "OK", total_time: 1},
                             foo: "bar"
                           )
    end

    it 'processes a failed response' do
      promise = Client.new('http://test.host').http :get, '/foods/burrito'
      promise.then ->(r) {}, ->(reason) { @response = reason }
      promise.handle_response double('Typhoeus::Response',
                                     response_code:500,
                                     connect_time:0.0,
                                     total_time:0.0,
                                     timed_out?: false,
                                     success?: false,
                                     status_message: '500 LOL',
                                     headers:{},
                                     body:'stuff',
                                     request: double('Typhoeus::Request', options: {method: 'get'}, url: 'http://foo'))

      expect(@response).to eq "HTTP GET http://foo\n500 500 LOL\n0.00s connect 0.00s total (completed)\n\n\n\nstuff"
    end
  end
end
