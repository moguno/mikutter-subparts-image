# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'

Plugin.create :sub_parts_image do
  UserConfig[:subparts_image_height] ||= 200

  settings "インライン画像表示" do
    adjustment("高さ(px)", :subparts_image_height, 10, 999)
  end

  on_boot do |service|
    # YouTube thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/youtu.be\//, nil) { |url, cancel|
      if url =~ /^http:\/\/youtu.be\/([^\/]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/^https:\/\/www\.youtube\.com\/watch\?v=/, nil) { |url, cancel|
      if url =~ /^https:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/
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
  end

  class Gdk::SubPartsImage < Gdk::SubParts
    regist

    def initialize(*args)
      super

      if message and not helper.visible?
        if message[:entities]
          target = message[:entities][:urls].map { |m| m[:expanded_url] }

          if message[:entities][:media]
            target += message[:entities][:media].map { |m| m[:media_url] }
          end

          page_url = nil

          target.each { |base_url|
            @image_url = Plugin[:openimg].get_image_url(base_url)

            if @image_url
              page_url = base_url
              break
            end
          }
        end

        if @image_url
          sid = helper.ssc(:expose_event, helper) {
            helper.on_modify
            helper.signal_handler_disconnect(sid)
            false 
          }

          helper.ssc(:click){ |this, e, x, y|
            offset = helper.mainpart_height

            helper.subparts.each{ |part|
              if part == self
                break
              end

              offset += part.height
            }

            if offset <= y && (offset + height) >= y
              Gtk::openurl(page_url)
            end
          }
        end
      end
    end

    def render(context)
      if helper.visible? and message and @image_url
        context.save{
          if !@main_icon
            @main_icon = Gdk::WebImageLoader.loading_pixbuf(UserConfig[:subparts_image_height], UserConfig[:subparts_image_height])

            raw = Gdk::WebImageLoader.get_raw_data(@image_url) {|data| 
              if data
                begin
                  loader = Gdk::PixbufLoader.new
                  loader.write data
                  loader.close
                  @main_icon = loader.pixbuf
                rescue => e
                  puts e
                  puts e.backtrace
                  @main_icon = Gdk::WebImageLoader.notfound_pixbuf(UserConfig[:subparts_image_height], UserConfig[:subparts_image_height])
                end
              else
                @main_icon = Gdk::WebImageLoader.notfound_pixbuf(UserConfig[:subparts_image_height], UserConfig[:subparts_image_height])
              end

              Delayer.new {
                helper.on_modify
              }
            }
          end 

          width_ratio = context.clip_extents[2] / @main_icon.melt.width 
          height_ratio = UserConfig[:subparts_image_height].to_f / @main_icon.melt.height
          scale_xy = [height_ratio, width_ratio].min
 
          context.translate((context.clip_extents[2] - @main_icon.melt.width * scale_xy) / 2, 0)
          context.scale(scale_xy, scale_xy)
          context.set_source_pixbuf(@main_icon)
          context.paint
        }
      end
    end

    def height
      if helper.visible? and message and @image_url
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
