
require 'awesome_print'
require 'logger'
require 'acpc_poker_player_proxy'
require 'rubame'

require_relative 'database_config'
require_relative '../app/models/match'
require_relative '../app/models/match_slice'

require 'contextual_exceptions'
using ContextualExceptions::ClassRefinement

module SimpleRubame
  refine Rubame::Server do
    # @return The first client to connect
    attr_reader :client
    def wait_for_client!(timeout=nil)
      readable, writable = IO.select(@reading, @writing, nil, timeout)

      if readable
        readable.each do |socket|
          client = @clients[socket]
          if socket == @socket
            @client = accept

            ap({readable: readable, writable: writable, client: @client})

            return self
          end
        end
      end

      ap({readable: readable, writable: writable, client: @client})

      return self
    end
  end
end
using SimpleRubame

# A proxy player for the web poker application.
class WebApplicationPlayerProxy
  # @todo Use contextual exceptions
  exceptions :unable_to_create_match_slice

  class << self
    def logger=(logger)
      @logger = logger
    end
    def logger
      @logger ||= Logger.new(STDERR)
    end
  end

  # @todo Reduce the # of params
  #
  # @param [String] match_id The ID of the match in which this player is participating.
  # @param [DealerInformation] dealer_information Information about the dealer to which this bot should connect.
  # @param [GameDefinition, #to_s] game_definition A game definition; either a +GameDefinition+ or the name of the file containing a game definition.
  # @param [String] player_names The names of the players in this match.
  # @param [Integer] number_of_hands The number of hands in this match.
  def initialize(
    match_id,
    dealer_information,
    users_seat,
    game_definition,
    player_names='user p2',
    number_of_hands=1
  )
    log __method__, {
      match_id: match_id,
      dealer_information: dealer_information,
      users_seat: users_seat,
      game_definition: game_definition,
      player_names: player_names,
      number_of_hands: number_of_hands
    }

    @match_id = match_id
    @player_proxy = AcpcPokerPlayerProxy::PlayerProxy.new(
      dealer_information,
      users_seat,
      game_definition,
      player_names,
      number_of_hands
    ) do |players_at_the_table|

      if players_at_the_table.transition.next_state
        update_database! players_at_the_table
      else
        log __method__, {before_first_match_state: true}
      end
    end
  end

  # Player action interface
  # @see PlayerProxy#play!
  def play!(action)
    log __method__, {action: action}

    @player_proxy.play! action do |players_at_the_table|
      update_database! players_at_the_table
    end

    self
  end

  # @see PlayerProxy#match_ended?
  def match_ended?
    match_has_ended = @player_proxy.players_at_the_table.match_ended?

    log __method__, {match_has_ended: match_has_ended}

    match_has_ended
  end

  private

  def update_database!(players_at_the_table)
    match = Match.find(@match_id)

    # @todo Move to PATT
    large_blind = players_at_the_table.player_blind_relation.values.max
    player_who_submitted_big_blind = players_at_the_table.player_blind_relation.key large_blind
    small_blind = players_at_the_table.player_blind_relation.reject do |player, blind|
      blind == large_blind
    end.values.max
    player_who_submitted_small_blind = players_at_the_table.player_blind_relation.key small_blind

    slice_attributes = {
      hand_has_ended: players_at_the_table.hand_ended?,
      match_has_ended: players_at_the_table.match_ended?,
      users_turn_to_act: players_at_the_table.users_turn_to_act?,
      hand_number: players_at_the_table.transition.next_state.hand_number,
      minimum_wager: players_at_the_table.min_wager,
      seat_with_small_blind: player_who_submitted_small_blind.seat,
      seat_with_big_blind: player_who_submitted_big_blind.seat,
      seat_with_dealer_button: players_at_the_table.player_with_dealer_button.seat,
      seat_next_to_act: if players_at_the_table.next_player_to_act
        players_at_the_table.next_player_to_act.seat
      end,
      state_string: players_at_the_table.transition.next_state.to_s,
      betting_sequence: players_at_the_table.betting_sequence_string,
      legal_actions: players_at_the_table.legal_actions.to_a.map do |action|
        action.to_s
      end,
      players: players_at_the_table.players.sort_by do |player|
        player.seat
      end.map do |player|
        player.to_h.merge(
          { amount_to_call: players_at_the_table.amount_to_call(player).to_f }
        )
      end,
      player_acting_sequence: players_at_the_table.player_acting_sequence_string
    }

    log __method__, slice_attributes

    begin
      match.slices.create! slice_attributes

      # Since creating a new slice doesn't "update" the match for some reason
      match.update_attribute(:updated_at, Time.now)
      match.save!

      unless @browser_connection && @browser_connection.client
        if @browser_connection
          @browser_connection.stop
        end
        @browser_connection = Rubame::Server.new("0.0.0.0", 25252)
        @browser_connection.wait_for_client!
      end
      if @browser_connection && @browser_connection.client
        ap "SENDING #{@match_id}"
        @browser_connection.client.send @match_id
        @browser_connection.stop if players_at_the_table.match_ended?
      end
    rescue => e
      @browser_connection.stop if @browser_connection
      raise UnableToCreateMatchSlice.with_context('Unable to create match slice', e)
    end

    self
  end

  def log(method, variables)
    WebApplicationPlayerProxy.logger.info "#{self.class}: #{method}: #{variables.awesome_inspect}"
  end
end
