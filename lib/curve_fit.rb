#
# Copyright 2010 Opscode, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require 'tempfile'

# A wrapper around cfityk (http://fityk.nieto.pl/) to handle fitting a curve to X+Y data, creating confidence intervals, and projecting up to a ceiling.
#
# Also supports basic manipulation of X+Y data files.
class CurveFit

  attr_accessor :debug

  def initialize(debug=false)
    @debug = debug
  end

  # Loads an x+y style data file as an array of arrays, suitable for passing to the fit method.
  #
  # @param [String] filename
  #   The filename to load.
  # @return [Array] data
  #   An X+Y array:
  #     [ [ X, Y ], [ X, Y ] ]
  def load_xy_file(filename)
    xy_data = Array.new
    File.open(filename, "r") do |xy_file|
      xy_file.each_line do |line|
        x, y = line.split(' ')
        xy_data << [ string_to_number(x), string_to_number(y) ]
      end
    end
    xy_data
  end

  # Takes a string of digits and converts it to an integer or a float,
  # depending on whether it rocks the dot. Returns the raw string if nothing
  # matches.
  #
  # @param [String] string
  # @return [Integer,Float,String] transformed_string
  def string_to_number(string)
    case string
    when /^\d+$/
      string.to_i
    when /^\d+.\d$/
      string.to_f
    else
      string
    end
  end

  # Adds an entry to an x+y style data file.
  #
  # @param [String] filename
  #   The filename to append to
  # @param [String] x
  #   The X value
  # @param [String] y
  #   The Y value
  # @return [True]
  def append_xy_file(filename, x, y)
    File.open(filename, 'a') do |xy_file|
      xy_file.puts "#{x} #{y}"
    end
    true
  end

  # Writes a data set out to an X+Y file
  #
  # @param [Array] data
  #   An X+Y array:
  #     [ [ X, Y ], [ X, Y ] ]
  # @param [String] filename
  #   If given, the filename to write. Otherwise, creates a tempfile.
  # @return [IO] data_file Returns the closed file IO object.
  def write_xy_file(data, filename=nil)
    data_file = nil
    if filename
      data_file = File.open(filename, "w")
    else
      data_file = Tempfile.new("curvefit")
      filename = data_file.path
    end

    data.each do |point|
      data_file.puts("#{point[0]} #{point[1]}")
    end

    data_file.close

    data_file
  end

  # Given an aray of X,Y data points, guesses the most correct curve (as measured by R-Squared) and
  # generates a trend line, top and bottom confidence intervals, and optionally projects the trend
  # to an artifical ceiling.
  #
  # @param [Array] data
  #   An array of arrays [[X, Y]..] representing the data set you want to curve fit.
  #
  # @param [Number, nil] ceiling
  #   The integer/float Y value to project the curve up to, the 'ceiling'. Nil
  #   means no projection past last X value.  Default is nil.
  #
  # @param [Array] guess_list
  #   A list of acceptable guesses to use in cfityk. As many of
  #   the following as desired: Linear, Quadratic, Cubic, Polynomial4, Polynomial5, Polynomial6. Default is all of the above.
  #
  # @param [Block] x_transform
  #   A block that will be passed a value for X from the original
  #   data set as an integer (1,2,3, etc), and should return a value to replace
  #   it with that matches the original data set.
  #
  # @return [Hash] A hash with the data, trend, top_confidence, and bottom_confidence as arrays of [X, Y], r_square and the guessed curve.
  #
  #  {
  #    :data => [ [ X, Y ], [ X, Y ] ... ],
  #    :trend => [ [ X, Y ], [ X, Y ] ... ],
  #    :top_confidence => [ [ X, Y ],  [X, Y] ...],
  #    :bottom_confidence => [ [ X, Y ], [X, Y] ...],
  #    :ceiling => [ [ X, Y ], [ X, Y ] ],
  #    :r_squared => 99.9764,
  #    :guess => "Quadratic"
  #  }
  #
  def fit(data, opts={}, &x_transform)
    ceiling = opts[:ceiling]
    guess_list = opts[:guess_list] || ["Linear", "Quadratic", "Cubic", "Polynomial4", "Polynomial5", "Polynomial6"]
    new_x_vals = Array(opts[:new_x_vals])
    data_file = Tempfile.new("curvefit")
    data.each do |point|
      data_file.puts("#{point[0]} #{point[1]}")
    end
    data_file.close

    guess_data = Hash.new

    guess_list.each do |shape|
      guess_data[shape] = Hash.new
      puts "Guessing #{shape} fit..." if @debug
      IO.popen("cfityk -I -q -c 'set autoplot=0 ; @0 < '#{data_file.path}'; guess #{shape}; fit; info formula; info fit; info errors;'") do |fityk_output|
        fityk_output.each_line do |line|
          puts "#{shape}: #{line}" if @debug
          case line
          # Polynomial6: -1.67142 + 3.04507*x + -1.78101*x^2 + 0.264354*x^3 + 0.000489333*x^4 + 0.000126697*x^5 + -5.4285e-07*x^6
          when /(.+) \+ (.+)\*x \+ (.+)\*x\^2 \+ (.+)\*x\^3 \+ (.+)\*x\^4 \+ (.+)\*x\^5 \+ (.+)\*x\^6/
            first = $1.to_f
            second = $2.to_f
            third = $3.to_f
            fourth = $4.to_f
            fifth = $5.to_f
            sixth = $6.to_f
            seventh = $7.to_f
            guess_data[shape][:curve_formula_args] = {
              1 => first,
              2 => second,
              3 => third,
              4 => fourth,
              5 => fifth,
              6 => sixth,
              7 => seventh
            }
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f + third * x.to_f**2 + fourth * x.to_f**3 + fifth * x.to_f**4 + sixth * x.to_f**5 + seventh * x.to_f**6
            }
          # Polynomial5: -1.67142 + 3.04507*x + -1.78101*x^2 + 0.264354*x^3 + 0.000489333*x^4 + 0.000126697*x^5
          when /(.+) \+ (.+)\*x \+ (.+)\*x\^2 \+ (.+)\*x\^3 \+ (.+)\*x\^4 \+ (.+)\*x\^5/
            first = $1.to_f
            second = $2.to_f
            third = $3.to_f
            fourth = $4.to_f
            fifth = $5.to_f
            sixth = $6.to_f
            guess_data[shape][:curve_formula_args] = {
              1 => first,
              2 => second,
              3 => third,
              4 => fourth,
              5 => fifth,
              6 => sixth
            }
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f + third * x.to_f**2 + fourth * x.to_f**3 + fifth * x.to_f**4 + sixth * x.to_f**5
            }
          # Polynomial4: -1.67142 + 3.04507*x + -1.78101*x^2 + 0.264354*x^3 + 0.000489333*x^4
          when /(.+) \+ (.+)\*x \+ (.+)\*x\^2 \+ (.+)\*x\^3 \+ (.+)\*x\^4/
            first = $1.to_f
            second = $2.to_f
            third = $3.to_f
            fourth = $4.to_f
            fifth = $5.to_f
            guess_data[shape][:curve_formula_args] = {
              1 => first,
              2 => second,
              3 => third,
              4 => fourth,
              5 => fifth
            }
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f + third * x.to_f**2 + fourth * x.to_f**3 + fifth * x.to_f**4
            }
          # Cubic: -1.67142 + 3.04507*x + -1.78101*x^2 + 0.264354*x^3
          when /(.+) \+ (.+)\*x \+ (.+)\*x\^2 \+ (.+)\*x\^3/
            first = $1.to_f
            second = $2.to_f
            third = $3.to_f
            fourth = $4.to_f
            guess_data[shape][:curve_formula_args] = {
              1 => first,
              2 => second,
              3 => third,
              4 => fourth
            }
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f + third * x.to_f**2 + fourth * x.to_f**3
            }
          # Quadratic: 1019.43 + 9.543*x + 0.202086*x^2
          when /(.+) \+ (.+)\*x \+ (.+)\*x\^2/
            first = $1.to_f
            second = $2.to_f
            third = $3.to_f
            guess_data[shape][:curve_forumla_args] = {
              1 => first,
              2 => second,
              3 => third
            }
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f + third * x.to_f**2
            }
          # Linear: 692.1 + 30.633 * x
          when /(.+) \+ (.+) \* x/
            first = $1.to_f
            second = $2.to_f
            guess_data[shape][:curve_formula] = lambda { |x|
              first + second * x.to_f
            }
          when /R2=(.+)/
            guess_data[shape][:r_squared] = $1.to_f
          # Error: $_1 = 692.1 +- 32.0558
          when /\$_(\d+) = ([\-\d\.e]+) \+\- ([\-\d\.]+)/
            guess_data[shape][:curve_error_args] ||= Hash.new
            guess_data[shape][:curve_error_args][$1.to_i] = [ $2.to_f, $3.to_f ]
          end
        end
      end

      if $?.exitstatus != 0
        raise "cfityk returned status #{$?.exitstatus} when guessing #{shape}, bailing"
      end

      if guess_data[shape][:r_squared] == 1
        guess_data[shape][:top_confidence_formula] = guess_data[shape][:curve_formula]
        guess_data[shape][:bottom_confidence_formula] = guess_data[shape][:curve_formula]
      else
        case shape
        when "Polynomial6"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] + curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] + curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] + curve_error_args[5][1]) * x.to_f**4 +
            (curve_error_args[6][0] + curve_error_args[6][1]) * x.to_f**5 +
            (curve_error_args[7][0] + curve_error_args[7][1]) * x.to_f**6
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] - curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] - curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] - curve_error_args[5][1]) * x.to_f**4 +
            (curve_error_args[6][0] - curve_error_args[6][1]) * x.to_f**5 +
            (curve_error_args[7][0] - curve_error_args[7][1]) * x.to_f**6
          }
        when "Polynomial5"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] + curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] + curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] + curve_error_args[5][1]) * x.to_f**4 +
            (curve_error_args[6][0] + curve_error_args[6][1]) * x.to_f**5
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] - curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] - curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] - curve_error_args[5][1]) * x.to_f**4 +
            (curve_error_args[6][0] - curve_error_args[6][1]) * x.to_f**5
          }
        when "Polynomial4"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] + curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] + curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] + curve_error_args[5][1]) * x.to_f**4
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] - curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] - curve_error_args[4][1]) * x.to_f**3 +
            (curve_error_args[5][0] - curve_error_args[5][1]) * x.to_f**4
          }
        when "Cubic"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] + curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] + curve_error_args[4][1]) * x.to_f**3
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] - curve_error_args[3][1]) * x.to_f**2 +
            (curve_error_args[4][0] - curve_error_args[4][1]) * x.to_f**3
          }
        when "Quadratic"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] + curve_error_args[3][1]) * x.to_f**2
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f +
            (curve_error_args[3][0] - curve_error_args[3][1]) * x.to_f**2
          }
        when "Linear"
          curve_error_args = guess_data[shape][:curve_error_args]
          guess_data[shape][:top_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] + curve_error_args[1][1]) +
            (curve_error_args[2][0] + curve_error_args[2][1]) * x.to_f
          }
          guess_data[shape][:bottom_confidence_formula] = lambda { |x|
            (curve_error_args[1][0] - curve_error_args[1][1]) +
            (curve_error_args[2][0] - curve_error_args[2][1]) * x.to_f
          }
        end
      end
    end

    best_fit_name = nil
    best_fit = nil
    guess_data.each do |shape, shape_guess|
      best_fit_name ||= shape
      best_fit ||= shape_guess
      if shape_guess[:r_squared] > best_fit[:r_squared]
        best_fit = shape_guess
        best_fit_name = shape
      end
    end

    trend_line = []
    top_confidence_line = []
    bottom_confidence_line = []
    ceiling_line = []

    x = 0
    y = 0

    no_ceiling = ceiling.nil?

    while(no_ceiling ? x < data.size : ceiling >= y)
      y = best_fit[:curve_formula].call(x)
      y_top_confidence = best_fit[:top_confidence_formula].call(x)
      y_bottom_confidence = best_fit[:bottom_confidence_formula].call(x)

      if x_transform
        trend_line << [ x_transform.call(x), y ]
        top_confidence_line << [ x_transform.call(x), y_top_confidence ]
        bottom_confidence_line << [ x_transform.call(x), y_bottom_confidence ]
        ceiling_line << [ x_transform.call(x), ceiling ] unless no_ceiling
      else
        trend_line << [ x, y ]
        top_confidence_line << [ x, y_top_confidence ]
        bottom_confidence_line << [ x, y_bottom_confidence ]
        ceiling_line << [ x, ceiling ] unless no_ceiling
      end

      x += 1
    end

    new_xy_vals = if new_x_vals
      new_x_vals.map{|x| [x, best_fit[:curve_formula].call(x)]}
    else
      nil
    end
    {
      :data              => data,
      :trend             => trend_line,
      :top_confidence    => top_confidence_line,
      :bottom_confidence => bottom_confidence_line,
      :ceiling           => ceiling_line,
      :r_squared         => best_fit[:r_squared],
      :guess             => best_fit_name,
      :new_xy_vals       => new_xy_vals
    }.reject{|x, y| y.nil?}
  end

end
