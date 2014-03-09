# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'

class ImageLoadHelper
  def self.get_image_url(message)
    result = nil

    if message[:entities]
      target = message[:entities][:urls].map { |m| m[:expanded_url] }

      if message[:entities][:media]
        target += message[:entities][:media].map { |m| m[:media_url] }
      end

      target.each { |base_url|
        image_url = Plugin[:openimg].get_image_url(base_url)

        if image_url
          result = {:page_url => base_url, :image_url => image_url}

          break
        end
      }
    end

    result
  end


  def self.load_start(message, &block)
    urls = get_image_url(message)

    if urls
      main_icon = nil
      parts_height = UserConfig[:subparts_image_height]

      image = Gdk::WebImageLoader.get_raw_data(urls[:image_url]) { |data, exception|

        if !exception && data
          begin
            loader = Gdk::PixbufLoader.new
            loader.write data
            loader.close
 
            main_icon = loader.pixbuf
          rescue => e
            puts e
            puts e.backtrace
            main_icon = Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
          end
        else
          main_icon = Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
        end

        if main_icon
          Delayer.new(Delayer::UI_PASSIVE) {
            block.call(urls, main_icon)
          }
        end
      }

      if image == :wait
        main_icon = Gdk::WebImageLoader.loading_pixbuf(parts_height, parts_height).melt
      else
        loader = Gdk::PixbufLoader.new
        loader.write image
        loader.close

        main_icon = loader.pixbuf
      end

      Delayer.new(Delayer::UI_PASSIVE) {
        block.call(urls, main_icon)
      }
    end
  end


  @@queue = nil

  def self.add(message, &block)
    if !@@queue
      @@queue = Queue.new

      Thread.start {
        while true
          msg = @@queue.pop
          load_start(msg[:message], &msg[:block])
        end
      }
    end

    @@queue.push({:message => message, :block => block})
  end
end


Plugin.create :sub_parts_image do
  UserConfig[:subparts_image_height] ||= 200
  UserConfig[:subparts_image_tp] ||= 100


  settings "インライン画像表示" do
    adjustment("高さ(px)", :subparts_image_height, 10, 999)
    adjustment("濃さ(%)", :subparts_image_tp, 0, 100)
  end


  on_boot do |service|
    # YouTube thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/youtu.be\//, nil) { |url, cancel|
      if url =~ /^http:\/\/youtu.be\/([^\?\/\#]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/^https?:\/\/www\.youtube\.com\/watch\?v=/, nil) { |url, cancel|
      if url =~ /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    # Nikoniko Video thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/nico.ms\/sm/, nil) { |url, cancel|
      if url =~ /^http:\/\/nico.ms\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/nicovideo\.jp\/watch\//, nil) { |url, cancel|
      if url =~ /nicovideo\.jp\/watch\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }
  end


  class Gdk::SubPartsImage < Gdk::SubParts
    regist

    def initialize(*args)
      super

      if message
        ImageLoadHelper.add(message) { |urls, pixbuf|
          if !helper.destroyed?
            sid = helper.ssc(:expose_event, helper) {
              helper.on_modify
              helper.signal_handler_disconnect(sid)
              false 
            }

            @ignore_event = false

            helper.ssc(:click) { |this, e, x, y|
              # なぜか２回連続でクリックイベントが飛んでくるのでアドホックに回避する
              if @ignore_event 
                next
              end

              offset = helper.mainpart_height

              helper.subparts.each { |part|
                if part == self
                  break
                end

                offset += part.height
              }

              if offset <= y && (offset + height) >= y
                case e.button
                when 1
                  Gtk::openurl(urls[:page_url])

                  @ignore_event = true

                  Thread.new {
                    sleep(0.5)
                    @ignore_event = false
                  }
                end
              end
            }
          end

          first_disp = (@main_icon == nil)
          @main_icon = pixbuf

          if first_disp
            helper.reset_height
          end

          helper.on_modify
        }
      end
    end


    def render(context)
      if @main_icon
        parts_height = UserConfig[:subparts_image_height]

        context.save {
          width_ratio = context.clip_extents[2] / @main_icon.width 
          height_ratio = parts_height.to_f / @main_icon.height
          scale_xy = [height_ratio, width_ratio].min
 
          context.translate((context.clip_extents[2] - @main_icon.width * scale_xy) / 2, 0)
          context.scale(scale_xy, scale_xy)
          context.set_source_pixbuf(@main_icon)
          context.paint(UserConfig[:subparts_image_tp] / 100.0)
        }
      end
    end


    def height
      if @main_icon
        UserConfig[:subparts_image_height]
      else
        0
      end
    end


    private

    def message
      helper.message
    end
  end
end
