"""Place the user's current operation frames next to rendered sample-data UI."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont


def main():
    root = Path('dist/current-reference')
    output = root / 'comparison'
    output.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype('C:/Windows/Fonts/msyh.ttc', 15)
    for frame, mode, timestamp in [('004', 'empty', '6 秒'),
                                    ('010', 'ab', '18 秒'),
                                    ('015', 'speeds', '28 秒')]:
        reference = Image.open(root / 'frames' / f'frame-{frame}.jpg').convert('RGB')
        rebuilt = Image.open(root / 'flutter' / f'player-390-{mode}.png').convert('RGB')
        reference = reference.resize((390, 844), Image.Resampling.LANCZOS)
        assert rebuilt.size == (390, 844), rebuilt.size
        canvas = Image.new('RGB', (792, 904), '#e8e9eb')
        canvas.paste(reference, (0, 30))
        canvas.paste(rebuilt, (402, 30))
        draw = ImageDraw.Draw(canvas)
        draw.text((9, 6), f'当前操作视频 · {timestamp}', font=font, fill='#222222')
        draw.text((411, 6), 'Flutter 重建 · 自带示例数据', font=font, fill='#222222')
        draw.text((9, 880), '比较页面结构与操作布局；媒体内容、系统状态栏不同。', font=font, fill='#555555')
        path = output / f'current-vs-flutter-{mode}.jpg'
        canvas.save(path, quality=94)
        print(path)


if __name__ == '__main__':
    main()
