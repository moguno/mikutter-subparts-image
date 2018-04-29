# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'

Plugin.create :"mikutter-subparts-image" do
  UserConfig[:subparts_image_tp] ||= 100
  UserConfig[:subparts_image_round] ||= 10
  UserConfig[:subparts_image_margin] ||= 2

  settings _("インライン画像表示") do
    adjustment(_("濃さ(%)"), :subparts_image_tp, 0, 100)
    adjustment(_("角を丸くする"), :subparts_image_round, 0, 200)
    adjustment(_("マージン(px)"), :subparts_image_margin, 0, 12)
  end


  defimageopener('youtube thumbnail (shrinked)', /^http:\/\/youtu.be\/([^\?\/\#]+)/) do |url|
    /^http:\/\/youtu.be\/([^\?\/\#]+)/.match(url)
    open("http://img.youtube.com/vi/#{$1}/0.jpg")
  end

  defimageopener('youtube thumbnail', /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/) do |url|
    /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/.match(url)
    open("http://img.youtube.com/vi/#{$1}/0.jpg")
  end

  defimageopener('niconico video thumbnail(shrinked)', /^http:\/\/nico.ms\/sm([0-9]+)/) do |url|
    /^http:\/\/nico.ms\/sm([0-9]+)/.match(url)
    open("http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}")
  end

  defimageopener('niconico video thumbnail', /nicovideo\.jp\/watch\/sm([0-9]+)/) do |url|
    /nicovideo\.jp\/watch\/sm([0-9]+)/.match(url)
    open("http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}")
  end


  # サブパーツ
  class Gdk::SubPartsImage < Gdk::SubParts
    register

    # クリック位置の特定
    def get_pointed_image_pos(x, y)
      offset = helper.mainpart_height

      helper.subparts.each { |part|
        if part == self
          break
        end

        offset += part.height
      }

      pointed_pos, = @num.times.each.map { |pos|
        rect = image_draw_area(pos, self.width)
        [pos, rect.x ... rect.x + rect.width, rect.y + offset ... rect.y + offset + rect.height]
      }.find { |url, xrange, yrange|
        xrange.include?(x) and yrange.include?(y)
      }

      pointed_pos
    end

    # イメージ取得完了
    def on_image_loaded(pos, pixbuf)
      # puts "#{@helper_message[0..10]} image loaded start #{pos}"

      if !helper.destroyed?
        # 再描画イベント
        sid = helper.ssc(:expose_event, helper) {
          # サブパーツ描画
          helper.on_modify
          helper.signal_handler_disconnect(sid)
          false
        }
      end

      # サブパーツ描画
      @main_icons[pos] = pixbuf

      # puts "#{@helper_message[0..10]} draw ready #{pos}"

      Delayer.new {
        # puts "#{@helper_message[0..10]} draw image #{pos}"
        helper.on_modify
      }
    end

    # 画像URLが解決したタイミング
    def on_image_information(urls)
      if urls.length == 0
        return
      end

      @mutex.synchronize {
        @num = urls.length

        if @height_reported
          Delayer.new {
            helper.reset_height
          }
        end
      }

      if !helper.destroyed?
        # クリックイベント
        @ignore_event = false

        if @click_sid
          helper.signal_handler_disconnect(@click_sid)
          @click_sid = nil
        end

        @click_sid = helper.ssc(:click) { |this, e, x, y|
          pos = get_pointed_image_pos(x, y)

          if pos
            clicked_url = urls[pos]

            case e.button
            when 1
              Plugin.call(:openimg_open, clicked_url) if clicked_url
            end
          end
        }

        if @motion_sid
          helper.signal_handler_disconnect(@motion_sid)
          @motion_sid = nil
        end

        @motion_event = helper.ssc(:motion_notify_event) { |this, x, y|
          pos = get_pointed_image_pos(x, y)

          if @draw_pos != pos
            @draw_pos = pos

            Delayer.new {
              helper.on_modify
            }
          end
        }

        if @leave_sid
          helper.signal_handler_disconnect(@leave_sid)
          @leave_sid = nil
        end

        @leave_sid = helper.ssc(:leave_notify_event) { |this|
          @draw_pos = nil

          Delayer.new {
            helper.on_modify
          }
        }
      end
    end

    # コンストラクタ
    def initialize(*args)
      super
      @num = 0
      @height_reported = false
      @mutex = Mutex.new
      @main_icons = []

      @helper_message = helper.message[:message]

      if message
        # イメージ読み込みスレッドを起こす
        Thread.new(message) { |message|
          urls =
            case
            when Plugin.instance_exist?(:score)
              # mikutter 3.7以降
              Plugin[:"mikutter-subparts-image"].score_of(message).map(&:uri)
            when message.links.is_a?(Retriever::Entity::BlankEntity)
              # mikutter3.5以降
              message.links.map { |_| _[:url] }
            else
              # mikutter 3.5未満
              message.entity
                .select{ |entity| %i<urls media>.include? entity[:slug] }
                .map { |entity|
                case entity[:slug]
                when :urls
                  entity[:expanded_url]
                when :media
                  entity[:media_url]
                end
              }
            end + Array(message[:subparts_images])

          streams = urls.map{ |url| Plugin.filtering(:openimg_raw_image_from_display_url, url.to_s, nil) }
                    .select{ |pair| pair.last }

          Delayer.new{ on_image_information streams.map(&:first) }

          streams.each.with_index do |pair, index|
            _, stream = *pair
            Thread.new {
              loader = Gdk::PixbufLoader.new
              loader.last_write(stream.read)
              stream.close
              pixbuf = loader.pixbuf

              Delayer.new {
                on_image_loaded(index, pixbuf)
              }
            }.trap{ |exception|
              puts "#{@helper_message[0..10]} #{exception}"
              error exception
            }
          end
        }.trap{ |exception| error exception }
      end
    end

    # 画像表示位置をキーにアスペクト比を求める
    def aspect_ratio(pos)
      case @num
      when 1, 4
        Rational(16, 9)
      when 2
        Rational(1, 1)
      when 3
        if pos == 0
          Rational(6, 9)
        else
          Rational(20, 9)
        end
      else
        Rational(16, 9)
      end
    end

    def aspect_ratio_x(pos)
      aspect_ratio(pos).numerator
    end

    def aspect_ratio_y(pos)
      aspect_ratio(pos).denominator
    end

    # 画像を描画する座標とサイズを返す
    # ==== Args
    # [pos] Fixnum 画像インデックス
    # [canvas_width] Fixnum キャンバスの幅(px)
    # ==== Return
    # Gdk::Rectangle その画像を描画する場所
    def image_draw_area(pos, canvas_width)
      case @num
      when 1
        height = 1 / aspect_ratio(pos) * canvas_width
        Gdk::Rectangle.new(0, height * pos, canvas_width, height)
      when 2
        width = canvas_width / 2
        height = 1 / aspect_ratio(pos) * width
        Gdk::Rectangle.new(width * pos, 0, width, height)
      when 3
        if pos == 0
          width = Rational(6, 16) * canvas_width
          height = 1 / aspect_ratio(pos) * width
          Gdk::Rectangle.new(0, 0, width, height)
        else
          x = Rational(6, 16) * canvas_width
          width = canvas_width - x
          height = 1 / aspect_ratio(pos) * width
          Gdk::Rectangle.new(x, height * (pos - 1), width, height)
        end
      else
        width = canvas_width / 2
        height = 1 / aspect_ratio(pos) * width
        Gdk::Rectangle.new(width * (pos % 2), (height + UserConfig[:subparts_image_margin]) * (pos / 2).floor, width, height)
      end
    end

    # rectをマージンぶんだけ縮小する。
    # マージンを取ることでrectのサイズが0以下になる場合は、マージンを開けずに返す
    # ==== Args
    # [rect] Gdk::Rectangle 縮小する前の領域
    # [margin] マージン(px)
    # ==== Return
    # Gdk::Rectangle 縮小した領域
    def add_margin(rect, margin)
      result = rect.dup
      if rect.width > margin * 2
        result.x += margin
        result.width -= margin * 2
      end
      if rect.height > margin * 2
        result.y += margin
        result.height -= margin * 2
      end
      result
    end

    # 画像を切り抜くさい、どこを切り抜くかを返す
    # ==== Args
    # [pos] Fixnum 画像インデックス
    # [base_area] Gdk::Pixbuf|Gdk::Rectangle 画像の寸法
    # [draw_area] Gdk::Rectangle 描画する場所の寸法
    # ==== Return
    # Gdk::Rectangle base_area内の切り抜く位置
    def image_crop_area(pos, base_area, draw_area)
      aspect_x = aspect_ratio_x(pos)
      aspect_y = aspect_ratio_y(pos)
      begin
        x_ratio = Rational(base_area.width, aspect_x)
        y_ratio = Rational(base_area.height, aspect_y)
        if x_ratio == y_ratio
          Gdk::Rectangle.new(0, 0, base_area.width, base_area.height)
        elsif x_ratio < y_ratio
          height = Rational(base_area.width * aspect_y, aspect_x)
          Gdk::Rectangle.new(0, (base_area.height - height) / 2, base_area.width, height)
        else
          width = Rational(base_area.height * aspect_x, aspect_y)
          Gdk::Rectangle.new((base_area.width - width) / 2, 0, width, base_area.height)
        end
      rescue ZeroDivisionError => err
        error err
      end
    end

    # サブパーツを描画
    def render(context)
      # 全画像プレビュー
      if !(@draw_pos && @main_icons[@draw_pos])
        @main_icons.compact.map.with_index { |icon, pos|
          draw_rect = image_draw_area(pos, self.width)
          crop_rect = image_crop_area(pos, icon, draw_rect)
          [icon, add_margin(draw_rect, UserConfig[:subparts_image_margin]), crop_rect]
        }.each { |icon, draw_rect, crop_rect|
          context.save {
            begin
              scale_x = Rational(draw_rect.width, crop_rect.width)
              scale_y = Rational(draw_rect.height, crop_rect.height)

              context.translate(draw_rect.x - (icon.width - crop_rect.width) * scale_x / 2,
                                draw_rect.y - (icon.height - crop_rect.height) * scale_y / 2)

              context.scale(scale_x, scale_y)
              context.set_source_pixbuf(icon)

              context.clip {
                round = Rational(UserConfig[:subparts_image_round], scale_x)
                context.rounded_rectangle(crop_rect.x, crop_rect.y, crop_rect.width, crop_rect.height, round)
              }
            rescue ZeroDivisionError => err
              error err
            end

            context.paint(UserConfig[:subparts_image_tp] / 100.0)
          }
        }
      else
        icon = @main_icons[@draw_pos]

        area_rect = add_margin(Gdk::Rectangle.new(0, 0, width, height), UserConfig[:subparts_image_margin])

        scale_x = area_rect.width.to_f / icon.width.to_f
        scale_y = area_rect.height.to_f / icon.height.to_f

        scale = [scale_x, scale_y].min

        start_x = area_rect.x.to_f + (area_rect.width.to_f - (icon.width.to_f * scale)) / 2.0
        start_y = area_rect.y.to_f + (area_rect.height.to_f - (icon.height.to_f * scale)) / 2.0

        draw_rect = Gdk::Rectangle.new(start_x.round, start_y.round, icon.width.to_f * scale, icon.height.to_f * scale)

        context.clip {
          round = UserConfig[:subparts_image_round]
          context.rounded_rectangle(draw_rect.x, draw_rect.y, draw_rect.width, draw_rect.height, round)
        }

        context.translate(draw_rect.x, draw_rect.y)
        context.scale(scale, scale)
        context.set_source_pixbuf(icon)

        context.paint(UserConfig[:subparts_image_tp] / 100.0)
      end
    end

    def height
      @mutex.synchronize {
        @height_reported = true
        if @num == 0
          0
        else
          draw_rect = image_draw_area(@num - 1, width)
          draw_rect.y + draw_rect.height
        end
      }
    end


    private

    def message
      helper.message
    end
  end
end
